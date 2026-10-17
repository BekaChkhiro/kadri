import SwiftUI
import KadriCore

struct StepCard: View {
    let step: Step?
    let parts: [Part]
    let index: Int
    let count: Int
    let streaming: Bool
    var previous: () -> Void
    var next: () -> Void
    var finish: () -> Void

    private var last: Bool { count > 0 && index == count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(SessionPresentation.progress(index: index, count: count, streaming: streaming))
                .font(.kadri(13, weight: .semibold))
                .foregroundStyle(Theme.Colors.brand[600]!)
            HStack(spacing: 4) {
                ForEach(0..<max(count, 1), id: \.self) { item in
                    Capsule().fill(item <= index && count > 0 ? Theme.Colors.brand[500]! : Theme.Colors.ink[900]!.opacity(0.1))
                        .frame(height: 4)
                }
            }
            .accessibilityHidden(true)
            if let step {
                VStack(alignment: .leading, spacing: 8) {
                    Text(step.title).font(.kadri(21, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(step.text).font(.kadri(14.5))
                        .foregroundStyle(Theme.Colors.ink[600]!)
                        .fixedSize(horizontal: false, vertical: true)
                    if !step.focus.isEmpty || !step.avoid.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(parts.filter { step.focus.contains($0.id) && !step.avoid.contains($0.id) }) { part in
                                    chip(part, avoid: false)
                                }
                                ForEach(parts.filter { step.avoid.contains($0.id) }) { part in
                                    chip(part, avoid: true)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).frame(width: 190, height: 22)
                    RoundedRectangle(cornerRadius: 6).frame(height: 14)
                    RoundedRectangle(cornerRadius: 6).frame(width: 240, height: 14)
                }
                .foregroundStyle(Theme.Colors.ink[900]!.opacity(0.08))
                .frame(minHeight: 100)
                .accessibilityHidden(true)
            }
            if streaming {
                Text(count == 0 ? "ინსტრუქციას ვამზადებ…" : "შემდეგი ნაბიჯი იწერება…")
                    .font(.kadri(12.5))
                    .foregroundStyle(Theme.Colors.ink[500]!)
            }
            HStack(spacing: 8) {
                Button("უკან", action: previous)
                    .buttonStyle(SessionButtonStyle(primary: false))
                    .disabled(index == 0 || count == 0)
                    .accessibilityLabel("უკან")
                    .accessibilityHint("წინა ნაბიჯს აჩვენებს")
                Button(last && !streaming ? "შესრულდა" : "შემდეგი") {
                    if last && !streaming { finish() } else { next() }
                }
                .buttonStyle(SessionButtonStyle())
                .disabled(count == 0 || (last && streaming))
                .accessibilityLabel(last && !streaming ? "შესრულდა" : "შემდეგი")
                .accessibilityHint(last && !streaming ? "დაასრულებს სესიას" : "შემდეგ ნაბიჯს აჩვენებს")
            }
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(16)
        .glass()
    }

    private func chip(_ part: Part, avoid: Bool) -> some View {
        // design-system's danger-600 uses the red fallback also shown in chemistry.tsx.
        let danger = Color(hex: "#dc2626")
        return Label(part.name, systemImage: avoid ? "xmark.circle.fill" : "scope")
            .font(.kadri(12.5, weight: .medium))
            .foregroundStyle(avoid ? danger : Theme.Colors.brand[700]!)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(avoid ? danger.opacity(0.08) : Theme.Colors.brand[50]!, in: Capsule())
            .accessibilityLabel("\(avoid ? "არ შეეხო" : "სამუშაო ნაწილი"): \(part.name)")
    }
}
