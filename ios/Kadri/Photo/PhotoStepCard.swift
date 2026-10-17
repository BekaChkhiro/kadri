import SwiftUI
import KadriCore

enum PhotoStepPresentation: Equatable {
    case next, preparing, finish

    static func state(index: Int, count: Int, streaming: Bool) -> Self {
        guard count > 0 else { return .preparing }
        if index < count - 1 { return .next }
        return streaming ? .preparing : .finish
    }

    var disabled: Bool { self == .preparing }
    var title: String {
        switch self {
        case .next: "შემდეგი"
        case .preparing: "მზადდება…"
        case .finish: "დასრულება"
        }
    }
}

struct PhotoStepCard: View {
    let step: Step?
    let index: Int
    let count: Int
    let streaming: Bool
    let caption: String?
    var previous: () -> Void
    var next: () -> Void
    var finish: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presentation: PhotoStepPresentation {
        .state(index: index, count: count, streaming: streaming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(SessionPresentation.progress(index: index, count: count, streaming: streaming))
                    .font(.kadri(13, weight: .semibold)).foregroundStyle(Theme.Colors.brand[600]!)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let caption {
                    Text(caption).font(.kadri(12, weight: .medium))
                        .foregroundStyle(Theme.Colors.ink[500]!).lineLimit(1)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<max(count, 1), id: \.self) { item in
                    Capsule().fill(item <= index && count > 0 ? Theme.Colors.brand[500]! : Theme.Colors.ink[900]!.opacity(0.1))
                        .frame(height: 4)
                }
            }.accessibilityHidden(true).padding(.top, 10)
            content.padding(.top, 14)
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .id(step?.index)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
            HStack(spacing: 8) {
                Button {} label: {
                    Image(systemName: "mic").font(.system(size: 20))
                }
                .buttonStyle(SessionButtonStyle(primary: false)).frame(width: 48)
                .disabled(true).accessibilityLabel("ხმით კითხვა — მალე")
                Button(action: previous) { Text("უკან").padding(.horizontal, 2) }
                    .buttonStyle(SessionButtonStyle(primary: false)).fixedSize(horizontal: true, vertical: false)
                    .disabled(index == 0 || count == 0)
                    .accessibilityLabel("უკან").accessibilityHint("წინა ნაბიჯს აჩვენებს")
                Button {
                    if presentation == .finish { finish() } else { next() }
                } label: {
                    HStack(spacing: 8) {
                        if presentation == .preparing {
                            ProgressView().controlSize(.small).tint(.white)
                        }
                        Text(presentation.title)
                        if presentation == .next { Image(systemName: "arrow.right").font(.system(size: 16)) }
                    }
                }
                .buttonStyle(SessionButtonStyle(primary: true))
                .shadow(Theme.Shadow.pop)
                .disabled(presentation.disabled)
                .accessibilityLabel(presentation.title)
                .accessibilityHint(presentation == .finish ? "დაასრულებს სესიას" : "შემდეგ ნაბიჯს აჩვენებს")
            }.padding(.top, 16)

        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(16).glass()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step?.index)
    }

    static func displayTitle(_ title: String) -> String {
        title.replacingOccurrences(of: #"^\s*\d+[.)]\s+"#, with: "", options: .regularExpression)
    }

    @ViewBuilder private var content: some View {
        if let step {
            VStack(alignment: .leading, spacing: 0) {
                Text(Self.displayTitle(step.title)).font(.kadri(21, weight: .semibold)).tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text(step.text).font(.kadri(14.5)).lineSpacing(4)
                    .foregroundStyle(Theme.Colors.ink[600]!).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                if !step.tools.isEmpty {
                    PhotoToolsLayout {
                        ForEach(Array(step.tools.prefix(3).enumerated()), id: \.offset) { _, tool in
                                Text(tool).font(.kadri(12.5, weight: .medium))
                                    .foregroundStyle(Theme.Colors.ink[700]!)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.white, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.Colors.ink[200]!, lineWidth: 1))
                            }
                    }.padding(.top, 12)
                }
                if let tip = step.tip {
                    Text(tip).font(.kadri(12.5)).foregroundStyle(Theme.Colors.brand[800]!)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: 12))
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
