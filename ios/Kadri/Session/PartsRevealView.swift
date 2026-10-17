import SwiftUI
import KadriCore

struct PartsRevealView: View {
    let parts: [Part]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(Array(parts.enumerated()), id: \.element.id) { index, part in
                    if let rect = SessionPresentation.rect(for: part, in: geometry.size) {
                        RoundedRectangle(cornerRadius: 20)
                            .fill(Theme.Colors.brand[500]!.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.Colors.brand[500]!, lineWidth: 2))
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                            .accessibilityHidden(true)
                        Text("\(index + 1) · \(part.name)")
                            .font(.kadri(12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(Theme.Colors.brand[500]!, in: Capsule())
                            .frame(width: min(180, geometry.size.width), alignment: .center)
                            .position(x: min(max(rect.midX, 90), max(90, geometry.size.width - 90)), y: max(18, rect.minY))
                            .accessibilityLabel("ნაწილი \(index + 1): \(part.name)")
                            .opacity(visible ? 1 : 0)
                            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.25).delay(reduceMotion ? 0 : Double(index) * 0.12), value: visible)
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { visible = true }
    }
}
