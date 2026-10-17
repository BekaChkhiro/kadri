import SwiftUI
import KadriCore

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

    private var last: Bool { count > 0 && index == count - 1 }
    private var finished: Bool { last && !streaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(SessionPresentation.progress(index: index, count: count, streaming: streaming))
                    .font(.kadri(13, weight: .semibold)).foregroundStyle(Theme.Colors.brand[600]!)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let caption {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.Colors.brand[500]!).frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                        Text(caption).font(.kadri(12, weight: .medium))
                            .foregroundStyle(Theme.Colors.ink[500]!).lineLimit(2)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<max(count, 1), id: \.self) { item in
                    Capsule().fill(item <= index && count > 0 ? Theme.Colors.brand[500]! : Theme.Colors.ink[900]!.opacity(0.1))
                        .frame(height: 4)
                }
            }.accessibilityHidden(true)
            content
                .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
                .id(step?.index)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: 8)))
            if step == nil || streaming {
                Text(step == nil ? "პირველი ნაბიჯი იწერება…" : "შემდეგი ნაბიჯი იწერება…")
                    .font(.kadri(12.5)).foregroundStyle(Theme.Colors.ink[500]!)
            }
            HStack(spacing: 8) {
                Button("უკან", action: previous)
                    .buttonStyle(SessionButtonStyle(primary: false)).frame(width: 84)
                    .disabled(index == 0 || count == 0)
                    .accessibilityLabel("უკან").accessibilityHint("წინა ნაბიჯს აჩვენებს")
                Button {
                    if finished { finish() } else { next() }
                } label: {
                    HStack(spacing: 8) {
                        Text(finished ? "დასრულდა" : "შესრულდა")
                        if !finished { Image(systemName: "arrow.right").font(.system(size: 16)) }
                    }
                }
                .buttonStyle(SessionButtonStyle(primary: true))
                .shadow(Theme.Shadow.pop)
                .disabled(count == 0 || (last && streaming))
                .accessibilityLabel(finished ? "დასრულდა" : "შესრულდა")
                .accessibilityHint(finished ? "დაასრულებს სესიას" : "შემდეგ ნაბიჯს აჩვენებს")
            }
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(16).glass()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: step?.index)
    }

    @ViewBuilder private var content: some View {
        if let step {
            VStack(alignment: .leading, spacing: 8) {
                Text(step.title).font(.kadri(21, weight: .semibold)).tracking(-0.3)
                    .accessibilityAddTraits(.isHeader)
                Text(step.text).font(.kadri(14.5)).lineSpacing(4)
                    .foregroundStyle(Theme.Colors.ink[600]!).fixedSize(horizontal: false, vertical: true)
                if !step.tools.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(step.tools.enumerated()), id: \.offset) { _, tool in
                                Text(tool).font(.kadri(12.5, weight: .medium))
                                    .foregroundStyle(Theme.Colors.ink[700]!)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(.white, in: Capsule())
                                    .overlay(Capsule().strokeBorder(Theme.Colors.ink[200]!, lineWidth: 1))
                            }
                        }
                    }.padding(.top, 4)
                }
                if let tip = step.tip {
                    Text(tip).font(.kadri(12.5)).foregroundStyle(Theme.Colors.brand[800]!)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.Colors.brand[50]!, in: RoundedRectangle(cornerRadius: 12))
                        .padding(.top, 4)
                }
                if let warn = step.warn {
                    Label(warn, systemImage: "exclamationmark.triangle.fill")
                        .font(.kadri(12.5)).foregroundStyle(Color(hex: "#b91c1c"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(hex: "#dc2626").opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityLabel("გაფრთხილება: \(warn)")
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
