import SwiftUI
import KadriCore

/// All photo phases share the same split: a square photo area (photos are centre-square crops, so they fill it exactly)
/// and the panel below. Keyboard avoidance shrinks the photo first, preserving enough panel space for the description.
struct PhotoScreenLayout<Photo: View, Panel: View>: View {
    let title: String
    var subtitle: String? = nil
    var close: () -> Void
    var newPhoto: () -> Void
    var newPhotoLabel = "სხვა ფოტო"
    var panelMinimumHeight: CGFloat = 210
    @ViewBuilder var photo: () -> Photo
    @ViewBuilder var panel: () -> Panel
    static var minimumPanelHeight: CGFloat { 210 }
    /// The photo keeps the same side inset as the panel's content.
    static var horizontalInset: CGFloat { 16 }

    var body: some View {
        VStack(spacing: 0) {
            PhotoHeader(title: title, subtitle: subtitle, close: close, newPhoto: newPhoto, newPhotoLabel: newPhotoLabel)
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
            GeometryReader { proxy in
                let side = max(0, min(proxy.size.width - 2 * Self.horizontalInset, proxy.size.height - panelMinimumHeight))
                VStack(spacing: 0) {
                    photo()
                        .allowsHitTesting(false)
                        .frame(width: side, height: side)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                        .accessibilityIdentifier("photo-area")
                    panel()
                        .frame(maxWidth: .infinity)
                        .frame(height: max(0, proxy.size.height - side))
                        .background(Theme.Colors.surface)
                        .accessibilityIdentifier("photo-panel")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .background(Theme.Colors.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
    }
}

struct PhotoHeader: View {
    let title: String
    var subtitle: String? = nil
    var close: () -> Void
    var newPhoto: () -> Void
    var newPhotoLabel = "სხვა ფოტო"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel("დახურვა").accessibilityHint("დახურავს ფოტო სესიას")
            VStack(spacing: 1) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.Colors.brand[500]!).frame(width: 10, height: 10)
                        .overlay {
                            Circle().stroke(Theme.Colors.brand[400]!.opacity(pulse ? 0 : 0.6), lineWidth: 2)
                                .scaleEffect(pulse ? 1.8 : 1)
                                .animation(reduceMotion ? nil : .easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                        }
                        .accessibilityHidden(true)
                    Text(title).font(.kadri(14, weight: .semibold)).lineLimit(1)
                }
                if let subtitle {
                    Text(subtitle).font(.kadri(11.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.ink[500]!).lineLimit(1)
                }
            }.frame(maxWidth: .infinity)
            Button(action: newPhoto) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel(newPhotoLabel).accessibilityHint("ახალი ფოტოს არჩევაზე გადავა")
        }
        .onAppear { pulse = !reduceMotion }
    }
}

struct PhotoChip: View {
    let text: String
    let symbol: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.kadri(12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background {
                Capsule().fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Theme.Colors.ink[900]!.opacity(0.55)))
            }
    }
}
