import SwiftUI
import KadriCore

/// Presentation rules shared by views and tests; boxes use the background view's coordinate space.
enum SessionPresentation {
    static func scanStatus(elapsed: TimeInterval) -> String {
        if elapsed > 10 { return "ცოტაც…" }
        if elapsed >= 3 { return "ვპოულობ ნაწილებს…" }
        return "ვათვალიერებ…"
    }

    static func rect(for part: Part, in size: CGSize) -> CGRect? {
        guard part.hasValidBox, size.width > 0, size.height > 0 else { return nil }
        let box = part.box.map { CGFloat($0) / 1000 }
        return CGRect(x: box[0] * size.width, y: box[1] * size.height,
                      width: (box[2] - box[0]) * size.width, height: (box[3] - box[1]) * size.height)
    }

    static func progress(index: Int, count: Int, streaming: Bool) -> String {
        guard count > 0 else { return "პირველი ნაბიჯი იწერება…" }
        // A later round's first step: the earlier rounds' steps are counted, the new one is not here yet.
        if streaming && index >= count { return "ნაბიჯი \(index + 1) იწერება…" }
        let current = min(max(index + 1, 1), count)
        return "ნაბიჯი \(current) / \(count)\(streaming ? "+" : "")"
    }
}

struct SessionButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.kadri(14.5, weight: .semibold))
            .frame(minHeight: 48)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 14)
            .foregroundStyle(primary ? .white : Theme.Colors.ink[800]!)
            .background(primary ? Theme.Colors.brand[500]! : Theme.Colors.ink[900]!.opacity(0.05),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.btn))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}
