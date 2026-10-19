import SwiftUI
import ARKit
import KadriCore

/// Counts distinct fresh camera frames actually presented, not timer callbacks.
struct LiveOverlayCadence {
    private var windowStart: TimeInterval?
    private var lastFrame: TimeInterval?
    private var frames = 0
    private(set) var fps: Double = 0

    mutating func presented(frame: TimeInterval?, now: TimeInterval) {
        if windowStart == nil { windowStart = now }
        if let frame, frame.isFinite, now >= frame, now-frame < 0.5, frame != lastFrame {
            frames += 1; lastFrame = frame
        }
        let elapsed = now-(windowStart ?? now)
        if elapsed >= 1 {
            fps = Double(frames)/elapsed
            frames = 0; windowStart = now
        }
    }
}

/// A stable UIKit overlay; SwiftUI updates metadata, never drives camera motion.
struct LiveCameraOverlay: UIViewRepresentable {
    let session: LiveCameraSession

    func makeUIView(context: Context) -> LiveCameraOverlayView {
        let view = LiveCameraOverlayView()
        view.session = session
        view.refreshLabels()
        return view
    }
    func updateUIView(_ view: LiveCameraOverlayView, context: Context) {
        view.session = session; view.refreshLabels()
    }
    static func dismantleUIView(_ view: LiveCameraOverlayView, coordinator: ()) { view.stop() }
}

@MainActor
final class LiveCameraOverlayView: UIView {
    weak var session: LiveCameraSession?
    private let contourView = ContourLayerView()
    private var pins: [String: LiveMarkerView] = [:]
    private var link: CADisplayLink?
    private var cadence = LiveOverlayCadence()
    private let target = Target()
    private var labels: [String: String] = [:]
    private var labelledParts: [Part] = []

    func refreshLabels() {
        let parts = session?.model.partsResult?.parts ?? []
        guard parts != labelledParts else { return }
        labelledParts = parts
        labels = Dictionary(parts.map { ($0.id, $0.name) },
                            uniquingKeysWith: { first, _ in first })
    }

    @MainActor private final class Target: NSObject {
        weak var owner: LiveCameraOverlayView?
        @objc func tick(_ link: CADisplayLink) { owner?.tick() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear; clipsToBounds = true
        addSubview(contourView)
        target.owner = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() { super.layoutSubviews(); contourView.frame = bounds }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { stop(); return }
        guard link == nil else { return }
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate(); link = nil; cadence = LiveOverlayCadence()
        session?.overlayFPS = 0; session?.overlayVisibleCount = 0
        apply(projections: [], contours: [], labels: [:], selectedID: nil)
    }

    private func tick() {
        guard let session, bounds.width > 0, bounds.height > 0 else { return }
        let now = CACurrentMediaTime()
        // Read currentFrame directly: no retained frame queue and no dependence
        // on a SwiftUI GeometryReader being reevaluated when the pose changes.
        let frame = session.controller.session.currentFrame
        let projections = frame.map {
            session.projections(frame: $0, viewport: bounds.size,
                                scale: window?.screen.scale ?? traitCollection.displayScale, now: now)
        } ?? []
        let contours = session.tracker.projected(projections, now: now)
        refreshLabels()
        apply(projections: projections, contours: contours, labels: labels, selectedID: session.selectedID)
        cadence.presented(frame: frame?.timestamp, now: now)
        session.overlayFPS = cadence.fps; session.overlayVisibleCount = projections.count
    }

    /// Reuses layers and controls. Also exercised with synthetic poses in hosted tests.
    func apply(projections: [PartProjection], contours: [TrackedContour], labels: [String: String], selectedID: String?) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let boxes = Dictionary(uniqueKeysWithValues: contours.map { ($0.id, $0.referenceBox) })
        contourView.update(contours: contours, boxes: boxes,
                           focus: Set([selectedID].compactMap { $0 }), avoid: [])
        let visible = Set(projections.map(\.id).filter { labels[$0] != nil })
        for id in Array(pins.keys) where !visible.contains(id) { pins.removeValue(forKey: id)?.removeFromSuperview() }
        for projection in projections {
            guard let label = labels[projection.id] else { continue }
            let pin: LiveMarkerView
            if let existing = pins[projection.id] { pin = existing }
            else {
                pin = LiveMarkerView()
                let id = projection.id
                pin.addAction(UIAction { [weak self] _ in self?.session?.selectedID = id }, for: .touchUpInside)
                pins[id] = pin; addSubview(pin)
            }
            pin.configure(title: label, selected: selectedID == projection.id)
            pin.center = projection.center
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self || hit === contourView ? nil : hit
    }
}

@MainActor
private final class LiveMarkerView: UIControl {
    private let dot = UIView()
    private let glass = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
    private let label = UILabel()
    private var title = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        dot.backgroundColor = UIColor(Theme.Colors.brand[500]!)
        dot.layer.cornerRadius = 6; dot.layer.borderColor = UIColor.white.cgColor; dot.layer.borderWidth = 2
        dot.isUserInteractionEnabled = false; glass.isUserInteractionEnabled = false
        glass.clipsToBounds = true
        label.font = Theme.ctFont(size: 12, weight: .semibold) as UIFont
        label.textColor = UIColor(Theme.Colors.ink[900]!)
        label.numberOfLines = 2; label.textAlignment = .center
        addSubview(dot); addSubview(glass); glass.contentView.addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, selected: Bool) {
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        if self.title != title || bounds.isEmpty {
            self.title = title; label.text = title; accessibilityLabel = title
            let size = label.sizeThatFits(CGSize(width: 130, height: 60))
            bounds.size = CGSize(width: min(150, max(44, size.width+20)), height: size.height+30)
            setNeedsLayout()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        dot.frame = CGRect(x: (bounds.width-12)/2, y: 0, width: 12, height: 12)
        glass.frame = CGRect(x: 0, y: 16, width: bounds.width, height: bounds.height-16)
        glass.layer.cornerRadius = glass.bounds.height/2
        label.frame = glass.bounds.insetBy(dx: 10, dy: 7)
    }
}
