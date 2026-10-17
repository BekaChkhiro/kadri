import SwiftUI
import KadriCore

enum PhotoTone {
    case brand, danger

    var color: Color { self == .danger ? Color(hex: "#dc2626") : Theme.Colors.brand[500]! }
}

struct PhotoMarkerPin: View {
    let number: Int
    let label: String
    let tone: PhotoTone
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle().fill(tone.color.opacity(0.25)).frame(width: 28, height: 28)
                Circle().fill(tone.color).frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                Text(tone == .danger ? "✕" : "\(number)").font(.kadri(12, weight: .bold)).foregroundStyle(.white)
            }
            Text(label).font(.kadri(12.5, weight: .semibold))
                .foregroundStyle(Theme.Colors.ink[800]!).lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .background(.white.opacity(0.9), in: Capsule())
                .shadow(Theme.Shadow.card)
        }
        .scaleEffect(reduceMotion || appeared ? 1 : 0.8)
        .opacity(reduceMotion || appeared ? 1 : 0)
        .onAppear { withAnimation(reduceMotion ? nil : .interpolatingSpring(stiffness: 420, damping: 30)) { appeared = true } }
    }
}

struct PhotoTargetFrame: View {
    let tone: PhotoTone
    let dashed: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20)
        shape.fill(dashed ? .white.opacity(0.15) : tone.color.opacity(0.1))
            .overlay {
                if dashed {
                    shape.strokeBorder(.white, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                } else {
                    shape.stroke(tone.color.opacity(0.18), lineWidth: 12).blur(radius: 1)
                    shape.stroke(tone.color, lineWidth: 2.5)
                }
            }
    }
}

/// The pause is part of the cycle, so both strokes and heads restart together.
private struct PhotoArrowTimeline<Content: View>: View {
    let duration: Double
    @ViewBuilder let content: (CGFloat, Double) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startedAt = Date()

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let linear = reduceMotion ? 1 : min(1, elapsed.truncatingRemainder(dividingBy: 1.8) / duration)
            let eased = (1 - cos(linear * .pi)) / 2
            content(CGFloat(eased), min(1, max(0, (linear - 0.8) / 0.2)))
        }
    }
}

struct TurnArrowView: View {
    let clockwise: Bool

    var body: some View {
        GeometryReader { proxy in
            PhotoArrowTimeline(duration: 1.1) { progress, head in
                ZStack {
                    TurnArc().trim(from: 0, to: progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: proxy.size.width * 0.06, lineCap: .round))
                    TurnHead().stroke(.white, style: StrokeStyle(lineWidth: proxy.size.width * 0.06, lineCap: .round, lineJoin: .round))
                        .opacity(head)
                }
            }
        }
        .scaleEffect(x: clockwise ? 1 : -1, y: 1)
        .shadow(color: Color(hex: "#0f172a").opacity(0.35), radius: 6, y: 2)
    }
}

private struct TurnArc: Shape {
    func path(in rect: CGRect) -> Path {
        let rise = sqrt(42.0 * 42.0 - 39.5 * 39.5)
        let angle = atan2(rise, 39.5) * 180 / .pi
        var path = Path()
        path.addArc(center: CGPoint(x: 50, y: 64.4 - rise), radius: 42,
                    startAngle: .degrees(180 - angle), endAngle: .degrees(360 + angle), clockwise: false)
        return path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100))
    }
}

private struct TurnHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 97.1, y: 58))
        path.addLine(to: CGPoint(x: 89.5, y: 64.4))
        path.addLine(to: CGPoint(x: 87.7, y: 54.6))
        return path.applying(CGAffineTransform(scaleX: rect.width / 100, y: rect.height / 100))
    }
}

struct MoveArrowView: View {
    enum Direction { case up, down, left, right }
    let direction: Direction

    var body: some View {
        GeometryReader { proxy in
            let endpoints = endpoints(in: proxy.size)
            let line = Path { path in
                path.move(to: endpoints.0)
                path.addLine(to: endpoints.1)
            }
            PhotoArrowTimeline(duration: 1.2) { progress, head in
                ZStack(alignment: .topLeading) {
                    line.stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 6, lineCap: .round, dash: [2, 10]))
                    line.trimmedPath(from: 0, to: progress)
                        .stroke(.white, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    MoveHead().stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
                        .frame(width: 32, height: 32).rotationEffect(rotation)
                        .position(endpoints.1).opacity(head)
                }
            }
        }
        .shadow(color: Color(hex: "#0f172a").opacity(0.35), radius: 6, y: 2)
    }

    private var rotation: Angle {
        switch direction {
        case .down: .degrees(0)
        case .up: .degrees(180)
        case .left: .degrees(90)
        case .right: .degrees(-90)
        }
    }

    private func endpoints(in size: CGSize) -> (CGPoint, CGPoint) {
        switch direction {
        case .down: (CGPoint(x: size.width / 2, y: 0), CGPoint(x: size.width / 2, y: size.height))
        case .up: (CGPoint(x: size.width / 2, y: size.height), CGPoint(x: size.width / 2, y: 0))
        case .left: (CGPoint(x: size.width, y: size.height / 2), CGPoint(x: 0, y: size.height / 2))
        case .right: (CGPoint(x: 0, y: size.height / 2), CGPoint(x: size.width, y: size.height / 2))
        }
    }
}

private struct MoveHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 5, y: 11))
        path.addLine(to: CGPoint(x: 12, y: 18))
        path.addLine(to: CGPoint(x: 19, y: 11))
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24))
    }
}

struct PhotoAnnotationsView: View {
    let step: Step?
    let parts: [Part]
    let boxes: [String: CGRect]
    let meshReady: Set<String>
    var visibleHeight: CGFloat? = nil
    var arrowSizeBoxes: [String: CGRect]? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let step {
                    ForEach(parts.filter { (step.focus.contains($0.id) || step.avoid.contains($0.id)) && !meshReady.contains($0.id) }) { part in
                        if let box = boxes[part.id] {
                            PhotoTargetFrame(tone: step.avoid.contains(part.id) ? .danger : .brand,
                                             dashed: step.arrows.contains { $0.part == part.id && $0.type == "move" })
                                .frame(width: box.width, height: box.height)
                                .position(x: box.midX, y: box.midY)
                        }
                    }
                    ForEach(Array(step.arrows.enumerated()), id: \.offset) { _, arrow in
                        if let box = boxes[arrow.part] { arrowView(arrow, box: box) }
                    }
                    ForEach(Array(step.markers.enumerated()), id: \.offset) { i, marker in
                        if let box = boxes[marker.part] {
                            let below = step.arrows.contains { $0.part == marker.part }
                            let pinWidth = min(220.0, max(0, proxy.size.width - 16))
                            PhotoMarkerPin(number: i + 1, label: marker.label,
                                           tone: marker.tone == "danger" || step.avoid.contains(marker.part) ? .danger : .brand)
                                .frame(width: pinWidth)
                                .position(x: min(max(box.midX, pinWidth / 2 + 8), max(pinWidth / 2 + 8, proxy.size.width - pinWidth / 2 - 8)),
                                          y: min(max(below ? box.maxY + 14 : box.minY - 14, 20), max(20, min(proxy.size.height, visibleHeight ?? proxy.size.height) - 20)))
                        }
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)

        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }

    @ViewBuilder private func arrowView(_ arrow: StepArrow, box: CGRect) -> some View {
        let sizeBox = arrowSizeBoxes?[arrow.part] ?? box
        if arrow.type == "rotate" {
            let size = min(160, max(72, max(sizeBox.width, sizeBox.height) * 1.25))
            TurnArrowView(clockwise: arrow.dir == "cw").frame(width: size, height: size)
                .position(x: box.midX, y: box.midY)
        } else if arrow.type == "move", let direction = direction(arrow.dir) {
            let vertical = arrow.dir == "up" || arrow.dir == "down"
            let length = max(60, (vertical ? sizeBox.height : sizeBox.width) * 0.6)
            let dx: CGFloat = arrow.dir == "left" ? -1 : arrow.dir == "right" ? 1 : 0
            let dy: CGFloat = arrow.dir == "up" ? -1 : arrow.dir == "down" ? 1 : 0
            MoveArrowView(direction: direction)
                .frame(width: vertical ? 32 : length, height: vertical ? length : 32)
                .position(x: box.midX + dx * length / 2, y: box.midY + dy * length / 2)
        }
    }

    private func direction(_ value: String) -> MoveArrowView.Direction? {
        switch value {
        case "up": .up
        case "down": .down
        case "left": .left
        case "right": .right
        default: nil
        }
    }
}
