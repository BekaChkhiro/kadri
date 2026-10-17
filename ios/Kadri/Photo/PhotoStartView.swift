import SwiftUI
import PhotosUI
import KadriCore

/// The first photo screen (photo-start.tsx): what Kadri does, the ways to bring a photo, and bundled examples.
struct PhotoStartView: View {
    var cameraAvailable: Bool
    var takePhoto: () -> Void
    @Binding var picked: PhotosPickerItem?
    var selectExample: (PhotoExample) -> Void
    var demo: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    private static let how: [(symbol: String, title: String, text: String)] = [
        ("camera", "გადაიღე", "ის, რაც გაწუხებს"),
        ("pencil", "აღწერე", "ერთი წინადადებით"),
        ("scope", "მიჰყევი", "მონიშნულ ნაწილებს"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                hero.padding(.top, 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("გადაუღე ფოტო,\nდანარჩენს მე გეტყვი")
                        .font(.kadri(28, weight: .semibold)).tracking(-0.5).lineSpacing(0)
                        .fixedSize(horizontal: false, vertical: true)
                        .photoEnter(0, appeared)
                    Text("კადრი ფოტოზე საჭირო ნაწილებს იპოვის და ნაბიჯ-ნაბიჯ გაგიძღვება.")
                        .font(.kadri(15)).foregroundStyle(Theme.Colors.ink[600]!).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                        .photoEnter(1, appeared)
                    actions.padding(.top, 24).photoEnter(2, appeared)
                    howItWorks.padding(.top, 28).photoEnter(3, appeared)
                }
                .padding(.horizontal, 20)
                examples.padding(.top, 28).photoEnter(4, appeared)
            }
            .padding(.bottom, 16)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .background(Theme.Colors.surface.ignoresSafeArea())
        .onAppear { appeared = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "scope").font(.system(size: 20)).foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Theme.Colors.brand[500]!, in: RoundedRectangle(cornerRadius: 12))
                .shadow(Theme.Shadow.pop)
                .accessibilityHidden(true)
            Text("კადრი").font(.kadri(18, weight: .semibold)).tracking(-0.3)
            Spacer()
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var hero: some View {
        // The PNG has no alpha and an off-white ground: lifted to white, multiply leaves only the surface behind it.
        ZStack {
            Theme.Colors.surface
            GeometryReader { proxy in
                Circle().fill(Theme.Colors.brand[100]!.opacity(0.7))
                    .padding(proxy.size.width * 0.08)
                    .blur(radius: 40)
            }
            if let image = UIImage(named: "illo-start") {
                Image(uiImage: image).resizable().scaledToFit().brightness(0.02).blendMode(.multiply)
            }
        }
        .compositingGroup()
        .aspectRatio(1, contentMode: .fit)
        .containerRelativeFrame(.horizontal) { width, _ in width * 0.78 }
        .frame(maxWidth: .infinity)
        .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.6), value: appeared)
        .accessibilityHidden(true)
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: takePhoto) {
                Label("გადაიღე ფოტო", systemImage: "camera").font(.kadri(16, weight: .semibold))
                    .frame(minHeight: 56)
            }
            .buttonStyle(SessionButtonStyle(primary: true))
            .disabled(!cameraAvailable)
            if !cameraAvailable {
                Text("ამ მოწყობილობაზე კამერა არ არის")
                    .font(.kadri(12)).foregroundStyle(Theme.Colors.ink[500]!)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            PhotosPicker(selection: $picked, matching: .images) {
                Label("აირჩიე გალერეიდან", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(SessionButtonStyle(primary: false))
            if let demo {
                Button("სატესტო ფოტო", action: demo)
                    .buttonStyle(SessionButtonStyle(primary: false))
            }
        }
    }

    private var howItWorks: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Array(Self.how.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: item.symbol).font(.system(size: 18))
                            .foregroundStyle(Theme.Colors.brand[600]!)
                            .frame(width: 32, height: 32)
                            .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: 10))
                        Spacer(minLength: 0)
                        Text("\(index + 1)").font(.kadri(12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.ink[300]!)
                    }
                    Text(item.title).font(.kadri(14, weight: .semibold)).padding(.top, 10)
                    Text(item.text).font(.kadri(12)).foregroundStyle(Theme.Colors.ink[500]!)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .shadow(Theme.Shadow.card)
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("როგორ მუშაობს")
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("სცადე მაგალითზე").font(.kadri(16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("ფოტოს გარეშე").font(.kadri(12.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.ink[500]!)
            }
            .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(PhotoExample.allCases, id: \.self) { example in
                        Button { selectExample(example) } label: { card(example) }
                            .buttonStyle(PhotoPressStyle())
                            .accessibilityLabel(example.label)
                            .accessibilityHint("მაგალითის ფოტოს გახსნის")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .padding(.vertical, -12)
        }
    }

    private func card(_ example: PhotoExample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Theme.Colors.ink[200]!
                .overlay {
                    if let image = example.image() {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .overlay {
                    LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0), .init(color: .clear, location: 0.5)],
                                   startPoint: .bottom, endPoint: .top)
                }
                .overlay(alignment: .bottomLeading) {
                    Image(systemName: "sparkles").font(.system(size: 14))
                        .foregroundStyle(Theme.Colors.brand[600]!)
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.9), in: Circle())
                        .padding(8)
                }
                .frame(width: 132, height: 132)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                .shadow(Theme.Shadow.card)
            Text(example.label).font(.kadri(13, weight: .semibold))
                .foregroundStyle(Theme.Colors.ink[800]!).lineLimit(1)
        }
        .frame(width: 132, alignment: .leading)
    }
}

/// Tap feedback for image cards (motion whileTap scale 0.97).
struct PhotoPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The artboards' staggered entrance: fade and rise, or only fade with Reduce Motion.
struct PhotoEnter: ViewModifier {
    let index: Int
    let shown: Bool
    var base = 0.08
    var rise: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : rise)
            .animation(reduceMotion ? .easeOut(duration: 0.15)
                       : .timingCurve(0.22, 1, 0.36, 1, duration: 0.4).delay(base + Double(index) * 0.07),
                       value: shown)
    }
}

extension View {
    func photoEnter(_ index: Int, _ shown: Bool, base: Double = 0.08, rise: CGFloat = 14) -> some View {
        modifier(PhotoEnter(index: index, shown: shown, base: base, rise: rise))
    }
}
