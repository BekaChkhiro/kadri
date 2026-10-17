import SwiftUI
import UIKit
import Vision
import KadriCore

/// Vision uses a bottom-left origin; consumers use the portrait image's top-left origin.
enum MaskContours {
    static func extract(_ mask: Mask) throws -> [[CGPoint]] {
        guard mask.width > 0, mask.height > 0, mask.pixels.count == mask.width * mask.height,
              let provider = CGDataProvider(data: Data(mask.pixels) as CFData),
              let image = CGImage(width: mask.width, height: mask.height, bitsPerComponent: 8,
                                  bitsPerPixel: 8, bytesPerRow: mask.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                                  decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return [] }
        let request = VNDetectContoursRequest()
        request.detectsDarkOnLight = false
        request.contrastAdjustment = 1
        request.maximumImageDimension = max(64, max(mask.width, mask.height))
        try VNImageRequestHandler(cgImage: image).perform([request])
        guard let observation = request.results?.first else { return [] }
        let polygons = observation.topLevelContours.map { contour in
            contour.normalizedPoints.map { CGPoint(x: CGFloat($0.x) * CGFloat(mask.width),
                                                   y: (1-CGFloat($0.y)) * CGFloat(mask.height)) }
        }
        let tolerance = 1.5 * CGFloat(max(mask.width, mask.height)) / 768
        return polygons.filter { $0.count >= 3 }.sorted { ContourGeometry.area($0) > ContourGeometry.area($1) }
            .prefix(2).map { polygon in
                ContourGeometry.simplify(polygon, tolerance: tolerance).map {
                    CGPoint(x: $0.x / CGFloat(mask.width), y: $0.y / CGFloat(mask.height))
                }
            }
    }
}

struct TrackedContour: Sendable, Identifiable {
    let id: String
    let polygons: [[CGPoint]]
    /// Normalized portrait box used to prompt this contour's segmentation.
    let referenceBox: CGRect
    let maskMs: Double
}

/// Reuses shape layers; each frame maps only simplified vertices into the projected box.
struct ContourOverlay: UIViewRepresentable {
    let contours: [TrackedContour]
    let boxes: [String: CGRect]
    var focus: Set<String> = []
    var avoid: Set<String> = []

    func makeUIView(context: Context) -> ContourLayerView { ContourLayerView() }
    func updateUIView(_ view: ContourLayerView, context: Context) {
        view.update(contours: contours, boxes: boxes, focus: focus, avoid: avoid)
    }
}

final class ContourLayerView: UIView {
    private struct Entry {
        let outer: CAShapeLayer
        let inner: CAShapeLayer
    }
    private var entries: [String: Entry] = [:]
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; backgroundColor = .clear }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(contours: [TrackedContour], boxes: [String: CGRect], focus: Set<String>, avoid: Set<String>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let ids = Set(contours.map(\.id))
        for id in Array(entries.keys) where !ids.contains(id) {
            entries.removeValue(forKey: id)?.outer.removeFromSuperlayer()
        }
        for contour in contours {
            let entry: Entry
            if let existing = entries[contour.id] { entry = existing }
            else {
                let outer = CAShapeLayer(), inner = CAShapeLayer()
                for shape in [outer, inner] { shape.fillColor = UIColor.clear.cgColor; shape.lineJoin = .round; shape.lineCap = .round }
                outer.addSublayer(inner); layer.addSublayer(outer)
                entry = Entry(outer: outer, inner: inner)
            }
            guard let box = boxes[contour.id], let transform = ContourGeometry.transform(from: contour.referenceBox, to: box) else {
                entry.outer.isHidden = true; entries[contour.id] = entry; continue
            }
            entry.outer.isHidden = false
            // Map normalized polygon to screen. Stroke remains constant in screen pixels.
            // A transformed path avoids scaling the stroke/glow with the object.
            let path = CGMutablePath()
            for polygon in contour.polygons {
                guard let first = polygon.first else { continue }
                path.move(to: first.applying(transform))
                polygon.dropFirst().forEach { path.addLine(to: $0.applying(transform)) }
                path.closeSubpath()
            }
            let scale = window?.screen.scale ?? traitCollection.displayScale
            let color = avoid.contains(contour.id) ? UIColor(Color(hex: "#ef4444"))
                : focus.contains(contour.id) ? UIColor(Theme.Colors.brand[500]!) : UIColor.white.withAlphaComponent(0.65)
            entry.outer.path = path; entry.inner.path = path
            entry.outer.strokeColor = color.cgColor; entry.outer.lineWidth = 3 / scale
            entry.inner.strokeColor = UIColor.white.cgColor; entry.inner.lineWidth = 1 / scale
            entry.outer.shadowColor = color.cgColor; entry.outer.shadowOpacity = 0.65
            entry.outer.shadowRadius = 5; entry.outer.shadowOffset = .zero
            entries[contour.id] = entry
        }
    }
}

@MainActor
final class ContourDisplayRate: NSObject, ObservableObject {
    @Published private(set) var fps: Double = 0
    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var count = 0
    @MainActor private final class Target: NSObject {
        weak var owner: ContourDisplayRate?
        @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
    }
    private let target = Target()
    func start() {
        guard link == nil else { return }
        target.owner = self
        let link = CADisplayLink(target: target, selector: #selector(Target.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common); self.link = link
    }
    func stop() { link?.invalidate(); link = nil; started = 0; count = 0; fps = 0 }
    private func tick(_ link: CADisplayLink) {
        if started == 0 { started = link.timestamp; return }
        count += 1
        let elapsed = link.timestamp - started
        if elapsed >= 1 { fps = Double(count) / elapsed; count = 0; started = link.timestamp }
    }
}
