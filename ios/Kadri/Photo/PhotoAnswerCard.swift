import SwiftUI
import KadriCore

/// A diagnostic turn on the current photo, with the footer kept above the keyboard.
struct PhotoAnswerCard: View {
    let continuation: StepsContinuation
    var submit: (String, String?) -> Void
    var back: () -> Void
    @State private var value = ""
    @State private var other = false
    @FocusState private var focused: Bool

    private var measurement: Bool {
        if case .needsMeasurement = continuation { return true }
        return false
    }

    private var question: String {
        switch continuation {
        case .needsAnswer(let question, _, _, _), .needsMeasurement(let question, _, _, _, _, _): question
        default: ""
        }
    }

    private var reason: String? {
        switch continuation {
        case .needsAnswer(_, _, _, let reason), .needsMeasurement(_, _, _, _, _, let reason): reason
        default: nil
        }
    }

    private var unit: String? {
        if case .needsMeasurement(_, let unit, _, _, _, _) = continuation { return unit }
        return nil
    }

    private var trimmed: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        guard !trimmed.isEmpty, trimmed.count <= 120 else { return false }
        return !measurement || Double(trimmed.replacingOccurrences(of: ",", with: "."))?.isFinite == true
    }

    private func send(_ answer: String, unit: String?) {
        focused = false
        submit(answer, unit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Label(measurement ? "გაზომვა" : "კითხვა", systemImage: measurement ? "gauge" : "questionmark.bubble")
                        .font(.kadri(12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.brand[700]!)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Theme.Colors.brand[50]!, in: Capsule())
                    Text(question).font(.kadri(20, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
                    if let reason, !reason.isEmpty {
                        Text(reason).font(.kadri(14.5)).foregroundStyle(Theme.Colors.ink[600]!)
                    }
                    if case .needsAnswer(_, let options, _, _) = continuation {
                        ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                            Button(option) { send(option, unit: nil) }
                                .buttonStyle(SessionButtonStyle(primary: false)).accessibilityLabel(option)
                        }
                    }
                    if measurement || other {
                        HStack {
                            TextField(measurement ? "მნიშვნელობა" : "შენი პასუხი", text: $value)
                                .keyboardType(measurement ? .decimalPad : .default)
                                .focused($focused).submitLabel(.send)
                                .accessibilityLabel(measurement ? "გაზომვის მნიშვნელობა" : "შენი პასუხი")
                                .onSubmit { if valid { send(trimmed, unit: unit) } }
                            if let unit { Text(unit).foregroundStyle(Theme.Colors.ink[500]!) }
                        }
                        .font(.kadri(16)).padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.Colors.ink[200]!))
                    }
                    if case .needsMeasurement(_, let unit, let min, let max, let how, _) = continuation {
                        Text(how).font(.kadri(12.5)).foregroundStyle(Theme.Colors.ink[500]!)
                        if let min, let max {
                            Text("დიაპაზონი: \(min.formatted())–\(max.formatted()) \(unit)")
                                .font(.kadri(12.5)).foregroundStyle(Theme.Colors.ink[500]!)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.scrollBounceBehavior(.basedOnSize)
            VStack(spacing: 8) {
                if measurement || other {
                    Button("გაგზავნა") { send(trimmed, unit: unit) }
                        .buttonStyle(SessionButtonStyle(primary: true)).disabled(!valid)
                        .accessibilityLabel("გაგზავნა")
                }
                HStack(spacing: 8) {
                    if measurement {
                        Button("არ მაქვს ხელსაწყო") { send("არ მაქვს ხელსაწყო", unit: nil) }
                            .buttonStyle(SessionButtonStyle(primary: false)).accessibilityLabel("არ მაქვს ხელსაწყო")
                    }
                    if case .needsAnswer(_, _, let allowOther, _) = continuation, allowOther && !other {
                        Button("სხვა") { other = true; focused = true }
                            .buttonStyle(SessionButtonStyle(primary: false)).accessibilityLabel("სხვა პასუხი")
                    }
                    Button("უკან", action: back).buttonStyle(SessionButtonStyle(primary: false))
                        .fixedSize(horizontal: measurement, vertical: false)
                        .accessibilityLabel("უკან").accessibilityHint("ნაბიჯებს დაუბრუნდება")
                }
            }
        }
        .foregroundStyle(Theme.Colors.ink[900]!).padding(16)
    }
}
