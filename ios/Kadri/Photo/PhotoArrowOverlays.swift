import SwiftUI
import CoreText
import KadriCore

/// Existing SF Symbols provide the shapes; motion communicates the requested action.
enum PhotoArrowKind: String, CaseIterable {
    case clockwise, counterclockwise, up, down, left, right
    case upLeft, upRight, downLeft, downRight, toward, away, press, hold, align

    init?(arrow: StepArrow) {
        guard let kind = Self.allCases.first(where: {
            $0.arrow.type == arrow.type && $0.arrow.dir == arrow.dir
        }) else { return nil }
        self = kind
    }

    var arrow: StepArrow {
        switch self {
        case .clockwise: .init(part: "p1", type: "rotate", dir: "cw")
        case .counterclockwise: .init(part: "p1", type: "rotate", dir: "ccw")
        case .press, .hold, .align: .init(part: "p1", type: rawValue, dir: "none")
        default: .init(part: "p1", type: "move", dir: wireDirection)
        }
    }

    private var wireDirection: String {
        switch self {
        case .upLeft: "up_left"
        case .upRight: "up_right"
        case .downLeft: "down_left"
        case .downRight: "down_right"
        default: rawValue
        }
    }

    var title: String {
        switch self {
        case .clockwise: "საათის ისრის მიმართულებით"
        case .counterclockwise: "საათის ისრის საწინააღმდეგოდ"
        case .up: "აწიე"
        case .down: "ჩამოწიე"
        case .left: "მარცხნივ"
        case .right: "მარჯვნივ"
        case .upLeft: "ზემოთ და მარცხნივ"
        case .upRight: "ზემოთ და მარჯვნივ"
        case .downLeft: "ქვემოთ და მარცხნივ"
        case .downRight: "ქვემოთ და მარჯვნივ"
        case .toward: "შენსკენ"
        case .away: "შენგან მოშორებით"
        case .press: "დააჭირე"
        case .hold: "გეჭიროს"
        case .align: "გაუსწორე"
        }
    }

    var symbolName: String {
        switch self {
        case .clockwise: "arrow.clockwise"
        case .counterclockwise: "arrow.counterclockwise"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .upLeft: "arrow.up.left"
        case .upRight: "arrow.up.right"
        case .downLeft: "arrow.down.left"
        case .downRight: "arrow.down.right"
        case .toward: "arrow.up.left.and.arrow.down.right"
        case .away: "arrow.down.right.and.arrow.up.left"
        case .press: "arrow.down.to.line"
        case .hold: "pause.circle"
        case .align: "scope"
        }
    }

    var vector: CGVector {
        let diagonal = CGFloat(1 / sqrt(2.0))
        return switch self {
        case .up: .init(dx: 0, dy: -1)
        case .down: .init(dx: 0, dy: 1)
        case .left: .init(dx: -1, dy: 0)
        case .right: .init(dx: 1, dy: 0)
        case .upLeft: .init(dx: -diagonal, dy: -diagonal)
        case .upRight: .init(dx: diagonal, dy: -diagonal)
        case .downLeft: .init(dx: -diagonal, dy: diagonal)
        case .downRight: .init(dx: diagonal, dy: diagonal)
        default: .zero
        }
    }

    var showsLabel: Bool { [.toward, .away, .press, .hold, .align].contains(self) }

    var labelWidth: CGFloat {
        let text = NSAttributedString(string: title, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): Theme.ctFont(size: 11, weight: .semibold)
        ])
        return ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)) + 18
    }
}

struct PhotoArrowLayout: Identifiable {
    let id: String
    let kind: PhotoArrowKind
    let anchor: CGPoint
    let center: CGPoint
    let size: CGFloat

    /// Keep sizing tied to the unzoomed part while anchoring to its current image position.
    static func make(arrows: [StepArrow], boxes: [String: CGRect],
                     sizeBoxes: [String: CGRect]? = nil, avoid: [String] = [],
                     viewport: CGSize, limit: Int = 3) -> [Self] {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width >= 40, viewport.height >= 40 else { return [] }
        let viewportRect = CGRect(origin: .zero, size: viewport)
        var used = Set<String>()
        return arrows.compactMap { arrow -> Self? in
            guard !avoid.contains(arrow.part), !used.contains(arrow.part),
                  let kind = PhotoArrowKind(arrow: arrow), let box = boxes[arrow.part],
                  isUsable(box), box.intersects(viewportRect) else { return nil }
            used.insert(arrow.part)
            let reference = sizeBoxes?[arrow.part].flatMap { isUsable($0) ? $0 : nil } ?? box
            let size = min(92, max(44, min(reference.width, reference.height) * 0.8),
                           min(viewport.width, viewport.height) * 0.5)
            let anchor = CGPoint(x: box.midX, y: box.midY)
            let vector = kind.vector
            // Leave room for the entire movement, not only its first animation frame.
            let margin = size * 0.8 + 8
            let labelMargin: CGFloat = kind.showsLabel ? 24 : 0
            let center = CGPoint(
                x: clamp(anchor.x + vector.dx * size * 0.25, margin, viewport.width - margin),
                y: clamp(anchor.y + vector.dy * size * 0.25, margin, viewport.height - margin - labelMargin))
            return Self(id: arrow.part, kind: kind, anchor: anchor, center: center, size: size)
        }.prefix(max(0, limit)).map { $0 }
    }

    /// A conservative envelope of the full motion plus its always-visible explanatory label.
    func occupiedRects(viewport: CGSize) -> [CGRect] {
        let radius = size * 0.8 + 4
        var result = [CGRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)]
        if kind.showsLabel { result.append(labelRect(viewport: viewport)) }
        return result
    }

    func labelRect(viewport: CGSize) -> CGRect {
        let width = min(kind.labelWidth, max(24, viewport.width - 16))
        let x = min(viewport.width - width / 2 - 8, max(width / 2 + 8, center.x))
        return CGRect(x: x - width / 2, y: center.y + size * 0.6,
                      width: width, height: 24)
    }

    private static func isUsable(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) && box.width > 0 && box.height > 0
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return max(0, (lower + upper) / 2) }
        return min(upper, max(lower, value))
    }
}

struct PhotoArrowMotion {
    let offset: CGSize
    let degrees: Double
    let scale: CGFloat
    let opacity: Double

    /// Move in one direction, fade out, then reset invisibly. Never animate an undo gesture.
    static func sample(kind: PhotoArrowKind, phase: CGFloat, size: CGFloat, reduced: Bool = false) -> Self {
        guard !reduced else { return .init(offset: .zero, degrees: 0, scale: 1, opacity: 1) }
        let phase = min(1, max(0, phase))
        let progress = min(1, phase / 0.72)
        let eased = progress * progress * (3 - 2 * progress)
        let opacity = min(1, phase / 0.1) * min(1, max(0, (0.94 - phase) / 0.15))
        let vector = kind.vector
        var scale: CGFloat = 1
        if kind == .toward { scale = 0.8 + eased * 0.4 }
        if kind == .away { scale = 1.2 - eased * 0.4 }
        if kind == .press { scale = 1 - eased * 0.16 }
        if kind == .align { scale = 1.15 - eased * 0.15 }
        let degrees: Double = kind == .clockwise ? Double(eased) * 65 :
            kind == .counterclockwise ? -Double(eased) * 65 : 0
        return .init(offset: .init(width: vector.dx * size * eased * 0.25,
                                  height: vector.dy * size * eased * 0.25),
                     degrees: degrees, scale: scale, opacity: kind == .hold ? 1 : Double(opacity))
    }
}

struct PhotoArrowOverlays: View {
    let arrows: [StepArrow]
    let boxes: [String: CGRect]
    var sizeBoxes: [String: CGRect]? = nil
    var avoid: [String] = []
    var previewPhase: CGFloat? = nil
    var visibleHeight: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.photoOverlayReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @State private var startedAt = Date()

    var body: some View {
        GeometryReader { proxy in
            let viewport = CGSize(width: proxy.size.width,
                                  height: max(0, min(proxy.size.height, visibleHeight ?? proxy.size.height)))
            let layouts = PhotoArrowLayout.make(arrows: arrows, boxes: boxes, sizeBoxes: sizeBoxes,
                                                avoid: avoid, viewport: viewport)
            TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || previewPhase != nil || layouts.isEmpty)) { timeline in
                let elapsed = max(0, timeline.date.timeIntervalSince(startedAt))
                let phase = previewPhase ?? CGFloat(elapsed.truncatingRemainder(dividingBy: 2.2) / 2.2)
                ZStack(alignment: .topLeading) {
                    ForEach(layouts) { layout in
                        let motion = PhotoArrowMotion.sample(kind: layout.kind, phase: phase,
                                                            size: layout.size, reduced: reduceMotion)
                        if layout.kind.vector != .zero {
                            Circle().fill(.white).frame(width: 6, height: 6)
                                .overlay(Circle().stroke(Theme.Colors.brand[500]!, lineWidth: 2))
                                .position(layout.anchor)
                        }
                        Image(systemName: layout.kind.symbolName)
                            .font(.system(size: layout.size * 0.76, weight: .bold))
                            .symbolRenderingMode(.monochrome)
                            .foregroundStyle(Theme.Colors.brand[500]!)
                            .shadow(color: .white, radius: 0, x: 2, y: 0)
                            .shadow(color: .white, radius: 0, x: -2, y: 0)
                            .shadow(color: .white, radius: 0, x: 0, y: 2)
                            .shadow(color: .white, radius: 0, x: 0, y: -2)
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
                            .frame(width: layout.size, height: layout.size)
                            .rotationEffect(.degrees(motion.degrees))
                            .scaleEffect(motion.scale)
                            .offset(motion.offset)
                            .opacity(motion.opacity)
                            .position(layout.center)
                        if layout.kind.showsLabel {
                            let label = layout.labelRect(viewport: viewport)
                            Text(layout.kind.title).font(.kadri(11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.brand[500]!)
                                .lineLimit(1).minimumScaleFactor(0.7)
                                .frame(width: label.width - 18)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(.white.opacity(0.95), in: Capsule())
                                .position(x: label.midX, y: label.midY)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
