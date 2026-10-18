import SwiftUI
import KadriCore

struct PhotoAskSheet: View {
    @ObservedObject var session: PhotoAskSession
    let image: UIImage
    let parts: [Part]
    let context: AskContext?
    var continueSteps: (String) -> Void = { _ in }
    @State private var question = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(session.selection?.label ?? "მონიშნული ნაწილი").font(.kadri(21, weight: .semibold))
                    ViewThatFits(in: .horizontal) {
                        HStack { questions }
                        VStack(alignment: .leading) { questions }
                    }
                    TextField("შენი კითხვა", text: $question, axis: .vertical)
                        .font(.kadri(16)).textFieldStyle(.roundedBorder)
                        .onChange(of: question) { question = String(question.prefix(200)) }
                        .accessibilityIdentifier("ask-question")
                    Button("გაგზავნა") { send(question) }
                        .buttonStyle(SessionButtonStyle())
                        .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.phase == .loading)
                    switch session.phase {
                    case .idle: EmptyView()
                    case .loading:
                        HStack { ProgressView(); Text("პასუხს ვამზადებ…"); Spacer(); Button("გაუქმება") { session.cancel() } }
                    case .error(let message):
                        Text(message).foregroundStyle(.red)
                        Button("სცადე თავიდან") { send(question) }
                    case .result(let result):
                        PhotoAskAnswer(result: result) { text in
                            session.dismiss(); continueSteps(text)
                        }
                    }
                }.padding(20)
            }
            .navigationTitle("შეეხე და იკითხე").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("დახურვა") { session.dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var questions: some View {
        ForEach(["ეს რა არის?", "მოვხსნა?", "რა ზომაა?"], id: \.self) { text in
            Button(text) { question = text; send(text) }
                .font(.kadri(14, weight: .medium)).buttonStyle(.bordered).disabled(session.phase == .loading)
        }
    }
    private func send(_ text: String) { session.submit(question: text, image: image, parts: parts, context: context) }
}

struct PhotoAskAnswer: View {
    let result: AskResult
    var continueSteps: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if result.urgency == .stop {
                Label("გაჩერდი", systemImage: "exclamationmark.octagon.fill")
                    .font(.kadri(18, weight: .bold)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            }
            Text(result.partLabel).font(.kadri(19, weight: .semibold))
            if result.confidence != .high { badge("სავარაუდო", confirmed: false) }
            Text(result.answer).font(.kadri(16))
            if let size = result.size {
                Text(size).font(.kadri(20, weight: .semibold))
                let confirmed = result.sizeSource == "seen" || result.sizeSource == "model"
                badge(confirmed ? "დადასტურებული" : "სავარაუდო — შეამოწმე", confirmed: confirmed)
                if let check = result.fitCheck { Text(check).font(.kadri(15)) }
            }
            if let next = result.suggestStep, !next.isEmpty {
                Button("ნაბიჯების გაგრძელება: \(next)") { continueSteps(next) }
                    .font(.kadri(16, weight: .medium)).buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(Theme.Colors.ink[50]!, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("ask-answer")
    }

    private func badge(_ text: String, confirmed: Bool) -> some View {
        Text(text).font(.kadri(12, weight: .semibold))
            .foregroundStyle(confirmed ? Theme.Colors.brand[500]! : Color.orange)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background((confirmed ? Theme.Colors.brand[500]! : Color.orange).opacity(0.1), in: Capsule())
    }
}
