import SwiftUI

/// Frosted light glass for every panel on top of the camera feed
/// (design-system.tsx `Glass`: border-white/60, bg-white/75, shadow-card, backdrop-blur-xl).
struct GlassModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.card

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.white.opacity(0.6)))
            }
            .overlay(shape.strokeBorder(Color.white.opacity(0.6), lineWidth: 1))
            .clipShape(shape)
            .shadow(Theme.Shadow.card)
    }
}

extension View {
    func glass(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassModifier(radius: radius))
    }
}
