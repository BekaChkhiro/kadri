import SwiftUI

struct DescribeBar: View {
    @Binding var text: String
    var submit: () -> Void
    @FocusState private var focused: Bool
    private let suggestions = ["ნიჟარა ჟონავს", "ზეთის შეცვლა", "სარეცხი მანქანა არ იწურება"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("რით დაგეხმარო?")
                .font(.kadri(21, weight: .semibold))
            HStack(alignment: .bottom, spacing: 8) {
                TextField("რა გინდა გააკეთო?", text: $text, axis: .vertical)
                    .font(.kadri(15))
                    .lineLimit(1...4)
                    .padding(12)
                    .background(.white.opacity(0.8), in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                    .focused($focused)
                    .accessibilityLabel("რა გინდა გააკეთო?")
                    .accessibilityHint("მოკლედ აღწერე პრობლემა")
                Button {
                    focused = false
                    submit()
                } label: {
                    Image(systemName: "arrow.up").frame(width: 20)
                }
                .buttonStyle(SessionButtonStyle())
                .frame(width: 48)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("გაგზავნა")
                .accessibilityHint("კამერის კადრში ნაწილების ძებნას დაიწყებს")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button { text = suggestion } label: {
                            Text(suggestion)
                                .font(.kadri(12.5, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background(.white.opacity(0.8), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(suggestion)
                        .accessibilityHint("ჩასვამს აღწერის ველში")
                    }
                }
            }
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(16)
        .glass()
    }
}
