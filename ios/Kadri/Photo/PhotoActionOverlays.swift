import SwiftUI
import KadriCore

struct PhotoActionOverlays: View {
    let actions: [StepAction]
    let boxes: [String: CGRect]
    var sizeBoxes: [String: CGRect]? = nil

    static let kinds: Set<String> = ["rotate_cw", "rotate_ccw", "press", "pull", "lift", "slide",
                                    "lever_up", "lever_down", "align", "tighten_order"]

    static func affectedParts(_ actions: [StepAction], boxes: [String: CGRect]) -> Set<String> {
        Set(visibleActions(actions, boxes: boxes).flatMap {
            $0.kind == "tighten_order" ? ($0.order ?? [$0.part]) : [$0.part]
        })
    }

    private static func visibleActions(_ actions: [StepAction], boxes: [String: CGRect]) -> [StepAction] {
        actions.prefix(3).filter {
            kinds.contains($0.kind) && boxes[$0.part] != nil &&
            ($0.kind != "tighten_order" || Set(($0.order ?? []).filter { boxes[$0] != nil }).count >= 2)
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(Self.visibleActions(actions, boxes: boxes).enumerated()), id: \.offset) { _, action in
                if Self.kinds.contains(action.kind), boxes[action.part] != nil {
                    if action.kind.hasPrefix("rotate_"), action.amount == nil {
                        let box = boxes[action.part]!
                        let size = Self.size(sizeBoxes?[action.part] ?? box)
                        TurnArrowView(clockwise: action.kind == "rotate_cw")
                            .frame(width: size, height: size).position(x: box.midX, y: box.midY)
                    } else {
                        let order = action.kind == "tighten_order"
                        PhotoArrowTimeline(duration: order ? 3 : 1.1, cycle: order ? 3 : 1.8) { progress, _ in
                            PhotoActionFrame(action: action, boxes: boxes, sizeBoxes: sizeBoxes, progress: progress)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    static func size(_ box: CGRect) -> CGFloat { min(160, max(72, max(box.width, box.height) * 1.25)) }
}

/// A deterministic frame also used by snapshots. Reduce Motion supplies progress = 1.
struct PhotoActionFrame: View {
    let action: StepAction
    let boxes: [String: CGRect]
    var sizeBoxes: [String: CGRect]? = nil
    let progress: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            if action.kind == "tighten_order" {
                let order = (action.order ?? []).filter { boxes[$0] != nil }
                let active = min(max(0, order.count - 1), Int(progress * CGFloat(order.count)))
                ForEach(Array(order.enumerated()), id: \.offset) { index, part in
                    if let box = boxes[part] {
                        Text("\(index + 1)").font(.kadri(15, weight: .bold))
                            .foregroundStyle(index == active ? .white : Theme.Colors.ink[800]!)
                            .frame(width: 32, height: 32)
                            .background(index == active ? Theme.Colors.brand[500]! : .white, in: Circle())
                            .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                            .position(x: box.midX, y: box.midY)
                    }
                }
            } else if let box = boxes[action.part] {
                let size = PhotoActionOverlays.size(sizeBoxes?[action.part] ?? box)
                if action.kind == "lift" {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: box.width, height: box.height)
                        .position(x: box.midX, y: box.midY - 10 * progress)
                }
                ActionGlyph(kind: action.kind, amount: action.amount, progress: progress)
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round,
                                                       dash: action.kind == "slide" ? [6, 5] : []))
                    .frame(width: size, height: size)
                    .position(x: box.midX, y: action.kind == "align" ? box.minY : box.midY)
                if action.kind.hasPrefix("rotate_"), let amount = action.amount {
                    Text(amount == "hand_tight_plus_quarter" ? "ხელით + ¼" : amount)
                        .font(.kadri(15, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Theme.Colors.ink[900]!.opacity(0.65), in: Capsule())
                        .position(x: box.midX, y: box.midY)
                }
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 1, y: 1)
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct ActionGlyph: Shape {
    let kind: String
    let amount: String?
    let progress: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        func line(_ a: CGPoint, _ b: CGPoint) { path.move(to: a); path.addLine(to: b) }
        func arrow(_ a: CGPoint, _ b: CGPoint) {
            line(a, b)
            let angle = atan2(b.y - a.y, b.x - a.x)
            for sign: CGFloat in [-1, 1] {
                line(b, CGPoint(x: b.x - 10 * cos(angle) + sign * 7 * sin(angle),
                                y: b.y - 10 * sin(angle) - sign * 7 * cos(angle)))
            }
        }
        let p = min(1, max(0, progress))
        switch kind {
        case "rotate_cw", "rotate_ccw":
            let degrees: CGFloat = amount == "½" ? 180 : amount == "1" ? 360 : 90
            let sign: CGFloat = kind == "rotate_cw" ? 1 : -1
            let end = -CGFloat.pi / 2 + sign * degrees * .pi / 180 * p
            path.addArc(center: CGPoint(x: 50, y: 50), radius: 36, startAngle: .degrees(-90),
                        endAngle: .radians(Double(end)), clockwise: sign < 0)
            let tip = CGPoint(x: 50 + 36 * cos(end), y: 50 + 36 * sin(end))
            let tangent = end + sign * .pi / 2
            for side: CGFloat in [-1, 1] {
                line(tip, CGPoint(x: tip.x - 10 * cos(tangent) + side * 7 * sin(tangent),
                                  y: tip.y - 10 * sin(tangent) - side * 7 * cos(tangent)))
            }
        case "press":
            let radius: CGFloat = 10 + 10 * p
            path.addEllipse(in: CGRect(x: 50 - radius, y: 65 - radius, width: radius * 2, height: radius * 2))
            path.addEllipse(in: CGRect(x: 44, y: 59, width: 12, height: 12))
            arrow(CGPoint(x: 50, y: 12), CGPoint(x: 50, y: 47 + 6 * p))
        case "pull":
            let hop = 8 * sin(p * .pi)
            arrow(CGPoint(x: 50, y: 50 + hop), CGPoint(x: 50, y: 88 + hop))
        case "lift":
            arrow(CGPoint(x: 50, y: 55 - 8 * p), CGPoint(x: 50, y: 12 - 8 * p))
        case "slide":
            arrow(CGPoint(x: 12, y: 50), CGPoint(x: 50 + 38 * p, y: 50))
        case "lever_up", "lever_down":
            let angle = (kind == "lever_up" ? -1.0 : 1.0) * .pi / 4 * p
            let pivot = CGPoint(x: 20, y: 50)
            path.addEllipse(in: CGRect(x: 16, y: 46, width: 8, height: 8))
            line(pivot, CGPoint(x: 20 + 60 * cos(angle), y: 50 + 60 * sin(angle)))
            path.move(to: CGPoint(x: 12, y: 63)); path.addLine(to: pivot); path.addLine(to: CGPoint(x: 28, y: 63))
        case "align":
            let gap = 22 * (1 - p)
            for sign: CGFloat in [-1, 1] {
                let x = 50 + sign * gap
                path.move(to: CGPoint(x: x, y: 50))
                path.addLine(to: CGPoint(x: x + sign * 14, y: 38))
                path.addLine(to: CGPoint(x: x + sign * 14, y: 62))
                path.closeSubpath()
            }
        default: break
        }
        return path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100))
    }
}
