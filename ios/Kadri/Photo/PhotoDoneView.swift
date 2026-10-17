import SwiftUI
import KadriCore

/// The end of a photo session (photo-done.tsx): a summary of what was done and a check that it worked.
struct PhotoDoneView: View {
    let object: String
    let steps: [Step]
    let photos: Int
    let minutes: Int
    let thumbnail: UIImage?
    var close: () -> Void
    var newPhoto: () -> Void
    var cause: String? = nil
    var diagnosticSummary: String? = nil
    var answers = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var fixed: Bool?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                hero.padding(.top, 4)
                VStack(spacing: 6) {
                    Text("მზადაა!").font(.kadri(27, weight: .semibold)).tracking(-0.5)
                        .accessibilityAddTraits(.isHeader)
                        .photoEnter(0, appeared, base: 0.25, rise: 12)
                    Text("ყველა \(steps.count) ნაბიჯი შესრულებულია.")
                        .font(.kadri(15)).foregroundStyle(Theme.Colors.ink[600]!)
                        .frame(maxWidth: 300)
                        .photoEnter(1, appeared, base: 0.25, rise: 12)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                VStack(spacing: 12) {
                    summary.photoEnter(2, appeared, base: 0.25, rise: 12)
                    check.photoEnter(3, appeared, base: 0.25, rise: 12)
                }
                .padding(.horizontal, 16).padding(.top, 20)
                actions.padding(.horizontal, 16).padding(.top, 20)
                    .photoEnter(4, appeared, base: 0.25, rise: 12)
            }
            .padding(.bottom, 8)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .background(Theme.Colors.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
        .onAppear { appeared = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel("დახურვა").accessibilityHint("დახურავს ფოტო სესიას")
            Text(object).font(.kadri(14, weight: .semibold)).foregroundStyle(Theme.Colors.ink[500]!)
                .lineLimit(1).frame(maxWidth: .infinity)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var hero: some View {
        // The PNG has no alpha and an off-white ground: lifted to white, multiply leaves only the surface behind it.
        ZStack {
            Theme.Colors.surface
            if let image = UIImage(named: "illo-done") {
                Image(uiImage: image).resizable().scaledToFit().brightness(0.03).blendMode(.multiply)
            }
        }
        .compositingGroup()
        .aspectRatio(1, contentMode: .fit)
        .containerRelativeFrame(.horizontal) { width, _ in width * 0.62 }
        .scaleEffect(appeared || reduceMotion ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.5, bounce: 0.25), value: appeared)
        .accessibilityHidden(true)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Theme.Colors.ink[200]!
                    .overlay { if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() } }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                HStack(spacing: 0) {
                    stat(steps.count, "ნაბიჯი")
                    Theme.Colors.ink[100]!.frame(width: 1)
                    stat(photos, "ფოტო")
                    if answers > 0 {
                        Theme.Colors.ink[100]!.frame(width: 1)
                        stat(answers, "პასუხი")
                    }
                    Theme.Colors.ink[100]!.frame(width: 1)
                    stat(minutes, "წუთი")
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if cause != nil || diagnosticSummary != nil {
                VStack(alignment: .leading, spacing: 8) {
                    if let cause { Text("ნაპოვნი მიზეზი: \(cause)").font(.kadri(15, weight: .semibold)) }
                    if let diagnosticSummary { Text(diagnosticSummary).font(.kadri(14)) }
                }
                .foregroundStyle(Theme.Colors.brand[800]!).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.brand[600]!)
                            .frame(width: 20, height: 20)
                            .background(Theme.Colors.brand[50]!, in: Circle())
                            .accessibilityHidden(true)
                        Text(PhotoStepCard.displayTitle(step.title)).font(.kadri(13.5))
                            .foregroundStyle(Theme.Colors.ink[600]!)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .overlay(alignment: .top) { Theme.Colors.ink[100]!.frame(height: 1) }
        }
        .padding(12)
        .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .shadow(Theme.Shadow.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("შეჯამება")
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text("\(value)").font(.kadri(19, weight: .semibold)).tracking(-0.3)
            Text(label).font(.kadri(11.5)).foregroundStyle(Theme.Colors.ink[500]!)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var check: some View {
        Group {
            if let fixed {
                Text(fixed ? "მშვენიერია! საქმე დასრულებულია." : "გადაუღე პრობლემურ ადგილს ახლოდან და თავიდან ვნახავ.")
                    .font(.kadri(14)).foregroundStyle(Theme.Colors.brand[900]!)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock").font(.system(size: 16)).accessibilityHidden(true)
                        Text("ერთი წუთის შემდეგ: გამოსწორდა?").font(.kadri(14, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Colors.brand[900]!)
                    HStack(spacing: 8) {
                        Button { answer(true) } label: {
                            Label("გამოსწორდა", systemImage: "checkmark").labelStyle(PhotoIconLabelStyle(size: 16))
                        }
                        .buttonStyle(SessionButtonStyle(primary: true))
                        Button { answer(false) } label: { Text("ისევ პრობლემაა") }
                            .buttonStyle(PhotoWhiteButtonStyle())
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }

    private func answer(_ value: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { fixed = value }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button(action: newPhoto) { Label("ახალი ფოტო", systemImage: "camera") }
                .buttonStyle(SessionButtonStyle(primary: fixed != nil))
                .accessibilityLabel("ახალი ფოტო")
            Button("მთავარზე", action: close)
                .buttonStyle(SessionButtonStyle(primary: false))
        }
    }
}

private struct PhotoIconLabelStyle: LabelStyle {
    let size: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: size, weight: .semibold))
            configuration.title
        }
    }
}

/// SessionButtonStyle's secondary button on a white fill, for use on tinted cards.
private struct PhotoWhiteButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kadri(14.5, weight: .semibold))
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .foregroundStyle(Theme.Colors.ink[800]!)
            .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.btn))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
