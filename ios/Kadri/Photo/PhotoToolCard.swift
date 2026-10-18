import SwiftUI
import KadriCore

struct PhotoToolCard: View {
    let tool: StepToolCard
    @ScaledMetric(relativeTo: .body) private var bodySize = 12.5
    @ScaledMetric(relativeTo: .headline) private var badgeSize = 22.0

    private var confirmed: Bool {
        tool.size != nil && ["seen", "model"].contains(tool.sizeSource)
    }
    private var accent: Color {
        confirmed ? Theme.Colors.brand[600]! : Color(hex: "#92400e")
    }
    private var profile: PhotoToolSymbol.Profile? { PhotoToolSymbol.profile(for: tool.id) }
    private var typeLabel: String? { profile?.title }
    private var sizeLabel: String? {
        guard let size = tool.size, !size.isEmpty else { return nil }
        return profile == .slotted && !size.contains("ბრტყელი") ? "ბრტყელი \(size)" : size
    }

    var body: some View {
        if let name = ToolCatalog.name(tool.id) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    illustration
                    VStack(alignment: .leading, spacing: 6) {
                        Text(name).font(.kadri(bodySize, weight: .semibold))
                            .foregroundStyle(Theme.Colors.ink[800]!)
                        if let sizeLabel {
                            Text(confirmed ? sizeLabel : "≈ \(sizeLabel)").font(.kadri(badgeSize, weight: .bold))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 9).padding(.vertical, 3)
                                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        } else if let typeLabel {
                            Text(typeLabel).font(.kadri(badgeSize, weight: .bold)).foregroundStyle(accent)
                        }
                    }
                }
                Label(confirmed ? "დადასტურებული" : "სავარაუდო — შეამოწმე",
                      systemImage: confirmed ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.kadri(bodySize, weight: .semibold)).foregroundStyle(accent)
                if !confirmed {
                    Text(tool.fitCheck?.isEmpty == false ? tool.fitCheck! : "ჯერ მორგება შეამოწმე; თუ თავისუფლად მოძრაობს, ძალას ნუ დაატან.")
                        .font(.kadri(bodySize)).foregroundStyle(Theme.Colors.ink[600]!)
                    if !tool.alternatives.isEmpty {
                        PhotoToolsLayout {
                            ForEach(Array(tool.alternatives.prefix(2).enumerated()), id: \.offset) { _, size in
                                Text("ან \(size)").font(.kadri(bodySize, weight: .medium))
                                    .padding(.horizontal, 9).padding(.vertical, 4)
                                    .background(Theme.Colors.ink[100]!, in: Capsule())
                            }
                        }
                    }
                }
                Text(tool.why).font(.kadri(bodySize)).foregroundStyle(Theme.Colors.ink[600]!)
                if let other = tool.notThis, let name = ToolCatalog.name(other.id) {
                    Label("არა: \(name) — \(other.reason)", systemImage: "xmark.circle")
                        .font(.kadri(bodySize)).foregroundStyle(Color(hex: "#b91c1c"))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "#fef2f2"), in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.Colors.ink[200]!, lineWidth: 1))
            .accessibilityElement(children: .combine)
        }
    }

    private var illustration: some View {
        PhotoToolSymbolView(toolID: tool.id)
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
    }
}

struct PhotoByHandCard: View {
    static func isVisible(for step: Step) -> Bool {
        (step.toolCards?.isEmpty ?? true) &&
        (step.hands?.contains { $0.isSupported && $0.byHandOnly } ?? false)
    }

    var body: some View {
        Label("ხელით შეგიძლია — ხელსაწყო არ სჭირდება", systemImage: "hand.raised")
            .font(.kadri(13, weight: .medium))
            .foregroundStyle(Theme.Colors.brand[800]!)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}
