import SwiftUI
import KadriCore

/// The panel under the photo while describing (photo-describe.tsx): suggestion tiles and the input row pinned below.
struct PhotoDescribePanel: View {
    @Binding var text: String
    var submit: () -> Void
    @FocusState private var focused: Bool
    @State private var appeared = false

    private static let suggestions: [(text: String, symbol: String)] = [
        ("ჟონავს", "drop"), ("არ ირთვება", "bolt.slash"),
        ("როგორ გავხსნა", "wrench"), ("როგორ ავაწყო", "sparkles"),
    ]
    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("რა გინდა გააკეთო?").font(.kadri(22, weight: .semibold)).tracking(-0.3)
                        .accessibilityAddTraits(.isHeader)
                    Text("აირჩიე ან დაწერე შენი სიტყვებით").font(.kadri(14))
                        .foregroundStyle(Theme.Colors.ink[500]!).padding(.top, 4)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        ForEach(Array(Self.suggestions.enumerated()), id: \.offset) { index, suggestion in
                            tile(suggestion.text, symbol: suggestion.symbol)
                                .photoEnter(index, appeared, base: 0.15, rise: 10)
                        }
                    }
                    .padding(.top, 16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            input
        }
        .padding(16)
        .foregroundStyle(Theme.Colors.ink[900]!)
        .onAppear { appeared = true }
    }

    private func tile(_ suggestion: String, symbol: String) -> some View {
        let selected = text == suggestion
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.card)
        return Button { text = suggestion } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18))
                    .foregroundStyle(selected ? .white : Theme.Colors.ink[600]!)
                    .frame(width: 32, height: 32)
                    .background(selected ? Theme.Colors.brand[500]! : Theme.Colors.ink[100]!,
                                in: RoundedRectangle(cornerRadius: 10))
                Text(suggestion).font(.kadri(13.5, weight: .semibold))
                    .foregroundStyle(selected ? Theme.Colors.brand[800]! : Theme.Colors.ink[800]!)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(selected ? Theme.Colors.brand[50]! : .white, in: shape)
            .overlay(shape.strokeBorder(selected ? Theme.Colors.brand[500]! : Theme.Colors.ink[200]!, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(PhotoPressStyle())
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityLabel(suggestion)
        .accessibilityHint("ჩასვამს აღწერის ველში")
        .accessibilityAddTraits(selected ? .isSelected : [])
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
                submit()
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
