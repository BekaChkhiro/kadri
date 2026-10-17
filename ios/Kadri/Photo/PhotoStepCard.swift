import SwiftUI
import KadriCore

enum PhotoStepPresentation: Equatable {
    case next, preparing, finish, newPhoto

    /// `needsPhoto`: the finished round asks for another photo, so its last step leads there instead of finishing.
    static func state(index: Int, count: Int, streaming: Bool, needsPhoto: Bool = false) -> Self {
        guard count > 0 else { return .preparing }
        if index < count - 1 { return .next }
        if streaming { return .preparing }
        return needsPhoto ? .newPhoto : .finish
    }

    var disabled: Bool { self == .preparing }
    var title: String {
        switch self {
        case .next: "შემდეგი"
        case .preparing: "მზადდება…"
        case .finish: "დასრულება"
        case .newPhoto: "ახალი ფოტო"
        }
    }

    var hint: String {
        switch self {
        case .finish: "დაასრულებს სესიას"
        case .newPhoto: "ახალი ფოტოს გადაღებას მოგთხოვს"
        default: "შემდეგ ნაბიჯს აჩვენებს"
        }
    }
}

struct PhotoStepCard: View {
    let step: Step?
    let index: Int
    let count: Int
    let streaming: Bool
    var previous: () -> Void
    var next: () -> Void
    var finish: () -> Void
    var needsPhoto = false
    var requestPhoto: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: PhotoStepPresentation {
        .state(index: index, count: count, streaming: streaming, needsPhoto: needsPhoto)
    }

    private var swap: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(SessionPresentation.progress(index: index, count: count, streaming: streaming))
                        .font(.kadri(13, weight: .semibold)).foregroundStyle(Theme.Colors.brand[600]!)
                    HStack(spacing: 4) {
                        ForEach(0..<max(count, 1), id: \.self) { item in
                            Capsule().fill(barColor(item)).frame(height: 4)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: index)
                    .accessibilityHidden(true).padding(.top, 10)
                    // Overlapping old and new content keeps the footer still while steps swap.
                    ZStack(alignment: .topLeading) {
                        content.id(index).transition(swap)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .animation(.easeOut(duration: 0.2), value: index)
                    .padding(.top, 16)
                    .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 8) {
                Button(action: previous) { Text("უკან").padding(.horizontal, 2) }
                    .buttonStyle(SessionButtonStyle(primary: false)).fixedSize(horizontal: true, vertical: false)
                    .disabled(index == 0 || count == 0)
                    .accessibilityLabel("უკან").accessibilityHint("წინა ნაბიჯს აჩვენებს")
                Button {
                    switch presentation {
                    case .finish: finish()
                    case .newPhoto: requestPhoto()
                    default: next()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if presentation == .preparing {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(presentation.title)
                        if presentation == .next || presentation == .newPhoto {
                            Image(systemName: "arrow.right").font(.system(size: 16))
                        }
                    }
                }
                .buttonStyle(SessionButtonStyle(primary: true))
                .shadow(Theme.Shadow.pop)
                .disabled(presentation.disabled)
                .accessibilityLabel(presentation.title)
                .accessibilityHint(presentation.hint)
            }.padding(.top, 12).padding(.horizontal, 16)

        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(.vertical, 16)
        .transaction { $0.animation = nil }
    }

    private func barColor(_ item: Int) -> Color {
        guard count > 0 else { return Theme.Colors.ink[900]!.opacity(0.1) }
        if item < index { return Theme.Colors.brand[300]! }
        if item == index { return Theme.Colors.brand[500]! }
        return Theme.Colors.ink[900]!.opacity(0.1)
    }

    static func displayTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
    }

    @ViewBuilder private var content: some View {
        if let step {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    if let symbol = PhotoIcon.action(step.icon) {
                        Image(systemName: symbol).font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white).frame(width: 44, height: 44)
                            .background(step.icon == "warning" ? Color(hex: "#dc2626") : Theme.Colors.brand[500]!,
                                        in: RoundedRectangle(cornerRadius: 14))
                            .shadow(Theme.Shadow.pop)
                            .accessibilityHidden(true)
                    }
                    Text(Self.displayTitle(step.title)).font(.kadri(21, weight: .semibold)).tracking(-0.3)
                        .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(step.text).font(.kadri(14.5)).lineSpacing(4)
                    .foregroundStyle(Theme.Colors.ink[600]!).fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                let tools = step.toolItems ?? step.tools.map { StepTool(label: $0) }
                if !tools.isEmpty {
                    PhotoToolsLayout {
                        ForEach(Array(tools.prefix(3).enumerated()), id: \.offset) { _, tool in
                                HStack(spacing: 6) {
                                    if let symbol = PhotoIcon.tool(tool.icon) {
                                        Image(systemName: symbol).font(.system(size: 14))
                                            .foregroundStyle(Theme.Colors.ink[500]!)
                                            .accessibilityHidden(true)
                                    }
                                    Text(tool.label).font(.kadri(12.5, weight: .medium))
                                }
                                    .foregroundStyle(Theme.Colors.ink[700]!)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.white, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.Colors.ink[200]!, lineWidth: 1))
                            }
                    }.padding(.top, 12)
                }
                if let tip = step.tip {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "lightbulb").font(.system(size: 16)).accessibilityHidden(true)
                        Text(tip).font(.kadri(12.5)).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(Theme.Colors.brand[800]!)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .padding(.top, 12)
                }
                if let warn = step.warn {
                    Text(warn)
                        .font(.kadri(12.5)).foregroundStyle(Color(hex: "#b91c1c"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(hex: "#fef2f2"), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("გაფრთხილება: \(warn)").padding(.top, 12)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                RoundedRectangle(cornerRadius: 6).frame(maxWidth: 190).frame(height: 22)
                RoundedRectangle(cornerRadius: 6).frame(height: 14)
                RoundedRectangle(cornerRadius: 6).frame(maxWidth: 240).frame(height: 14)
            }
            .foregroundStyle(Theme.Colors.ink[900]!.opacity(0.08))
            .accessibilityHidden(true)
        }
    }
}

/// Chips wrap using their measured widths, including at larger accessibility sizes.
private struct PhotoToolsLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 320, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, view) in subviews.enumerated() {
            view.place(at: CGPoint(x: bounds.minX + layout.points[index].x, y: bounds.minY + layout.points[index].y),
                       anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var points: [CGPoint] = []
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + 6; rowHeight = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + 6
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), points)
    }
}

/// Keep the wire enum separate from SF names; unknown or unavailable symbols have no visual fallback.
enum PhotoIcon {
    private static let actions = [
        "rotate_cw": "arrow.clockwise", "rotate_ccw": "arrow.counterclockwise",
        "unscrew": "arrow.counterclockwise.circle", "tighten": "arrow.clockwise.circle",
        "pull": "arrow.up", "push": "arrow.down", "press": "hand.tap", "open": "lock.open",
        "close": "lock", "pour": "drop", "check": "checkmark.circle", "clean": "sparkles",
        "place": "square.and.arrow.down", "remove": "minus.circle", "wait": "clock",
        "warning": "exclamationmark.triangle"
    ]
    private static let tools = [
        "wrench": "wrench", "screwdriver": "screwdriver", "pliers": "wrench.adjustable",
        "hex_key": "hexagon", "hammer": "hammer", "bucket": "bucket", "gloves": "hand.raised",
        "towel": "rectangle.portrait", "cloth": "rectangle.portrait", "brush": "paintbrush",
        "flashlight": "flashlight.on.fill", "tape": "bandage", "knife": "scissors", "funnel": "triangle",
        "container": "cube", "oil": "drop.fill", "water": "drop", "cable": "cable.connector",
        "phone": "iphone", "paper": "doc"
    ]

    static func action(_ key: String?) -> String? { available(key.flatMap { actions[$0] }) }
    static func tool(_ key: String?) -> String? {
        available(key.flatMap { tools[$0] }) ?? (key == "bucket" ? available("cylinder") : nil)
    }

    private static func available(_ symbol: String?) -> String? {
        guard let symbol, UIImage(systemName: symbol) != nil else { return nil }
        return symbol
    }
}
