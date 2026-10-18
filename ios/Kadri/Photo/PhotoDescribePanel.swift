import SwiftUI
import KadriCore

/// A free-form description and provider selection below the captured photos.
struct PhotoDescribePanel: View {
    @Binding var text: String
    @AppStorage("photoAIProvider") private var provider: AIProvider = .astra
    var submit: (AIProvider) -> Void
    @FocusState private var focused: Bool

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("რა გინდა გააკეთო?").font(.kadri(22, weight: .semibold)).tracking(-0.3)
                        .accessibilityAddTraits(.isHeader)
                    Text("აღწერე პრობლემა შენი სიტყვებით").font(.kadri(14))
                        .foregroundStyle(Theme.Colors.ink[500]!).padding(.top, 4)

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { focused = false }
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
            Picker("AI", selection: $provider) {
                Text("Astra").tag(AIProvider.astra)
                Text("Gemini").tag(AIProvider.gemini)
            }
            .pickerStyle(.segmented)
            .font(.kadri(13, weight: .semibold))
            .tint(Theme.Colors.brand[500]!)
            .accessibilityLabel("AI მოდელი")
            input
        }
        .padding(16)
        .foregroundStyle(Theme.Colors.ink[900]!)
    }

    private var input: some View {
        let field = RoundedRectangle(cornerRadius: Theme.Radius.card)
        return HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                TextField("მაგ.: ქანჩთან წვეთავს", text: $text, axis: .vertical)
                    .font(.kadri(15))
                    .lineLimit(1...4)
                    .padding(.vertical, 15)
                    .focused($focused)
                    .accessibilityLabel("რა გინდა გააკეთო?")
                    .accessibilityHint("მოკლედ აღწერე პრობლემა")
                Button {} label: {
                    Image(systemName: "mic").font(.system(size: 18))
                        .foregroundStyle(Theme.Colors.ink[500]!)
                        .frame(width: 40, height: 40)
                }
                .disabled(true)
                .padding(.bottom, 6)
                .accessibilityLabel("ხმით კითხვა — მალე")
            }
            .padding(.leading, 16).padding(.trailing, 6)
            .frame(minHeight: 52)
            .background(.white, in: field)
            .overlay(field.strokeBorder(focused ? Theme.Colors.brand[500]! : Theme.Colors.ink[200]!, lineWidth: 1))
            .shadow(Theme.Shadow.card)
            .animation(.easeOut(duration: 0.15), value: focused)
            Button {
                focused = false
                submit(provider)
            } label: {
                Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isEmpty ? Theme.Colors.ink[400]! : .white)
                    .frame(width: 52, height: 52)
                    .background(isEmpty ? Theme.Colors.ink[200]! : Theme.Colors.brand[500]!,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .shadow(isEmpty ? ShadowStyle(color: .clear, radius: 0, y: 0) : Theme.Shadow.pop)
            }
            .buttonStyle(PhotoPressStyle())
            .disabled(isEmpty)
            .accessibilityLabel("გაგზავნა")
            .accessibilityHint("კამერის კადრში ნაწილების ძებნას დაიწყებს")
        }
    }
}
