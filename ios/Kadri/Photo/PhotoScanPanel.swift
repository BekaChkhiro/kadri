import SwiftUI
import KadriCore

/// The panel under the photo while scanning (photo-scan.tsx): a staged checklist and a cancel button.
struct PhotoScanPanel: View {
    let startedAt: Date
    var cancel: () -> Void

    static let stages = ["ფოტოს ვათვალიერებ", "ვპოულობ ნაწილებს", "ვწერ ნაბიჯებს"]

    /// Follows SessionPresentation.scanStatus: looking until 3 s, then finding parts. The steps stage
    /// stays ahead — the steps screen replaces this one as soon as the parts arrive.
    static func activeStage(elapsed: TimeInterval) -> Int { elapsed >= 3 ? 1 : 0 }

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: startedAt, by: 0.5)) { context in
                let active = Self.activeStage(elapsed: context.date.timeIntervalSince(startedAt))
                VStack(spacing: 0) {
                    ForEach(Array(Self.stages.enumerated()), id: \.offset) { index, title in
                        PhotoScanStageRow(title: title, state: index < active ? .done : index == active ? .active : .todo)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(.white, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
                .shadow(Theme.Shadow.card)
                .animation(.spring(duration: 0.4, bounce: 0.3), value: active)
            }
            Spacer(minLength: 0)
            Button("გაუქმება", action: cancel)
                .buttonStyle(SessionButtonStyle(primary: false))
        }
        .padding(16)
        .foregroundStyle(Theme.Colors.ink[900]!)
    }
}

private struct PhotoScanStageRow: View {
    enum State { case done, active, todo }
    let title: String
    let state: State

    var body: some View {
        HStack(spacing: 12) {
            indicator.frame(width: 28, height: 28)
            Text(state == .active ? title + "…" : title)
                .font(.kadri(15, weight: state == .done ? .medium : state == .active ? .semibold : .regular))
                .foregroundStyle(state == .done ? Theme.Colors.ink[500]! : state == .active ? Theme.Colors.ink[900]! : Theme.Colors.ink[400]!)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(state == .done ? "დასრულდა" : state == .active ? "მიმდინარეობს" : "მოლოდინში")
    }

    @ViewBuilder private var indicator: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Theme.Colors.brand[500]!, in: Circle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        case .active:
            PhotoScanSpinner()
        case .todo:
            Circle().stroke(Theme.Colors.ink[200]!, style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                .frame(width: 24, height: 24)
        }
    }
}

private struct PhotoScanSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            ZStack {
                Circle().stroke(Theme.Colors.brand[100]!, lineWidth: 2.5)
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Theme.Colors.brand[500]!, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(turn * 360 - 90))
            }
            .frame(width: 24, height: 24)
        }
    }
}

/// The scan beam sweeping down over the photo (photo-scan.tsx): hidden with Reduce Motion.
struct PhotoScanBeam: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let period = 2.2
    private static let height: CGFloat = 96

    var body: some View {
        if !reduceMotion {
            GeometryReader { proxy in
                TimelineView(.animation) { context in
                    let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
                    let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                    let top = proxy.size.height * (-0.25 + 1.25 * eased)
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, Theme.Colors.brand[500]!.opacity(0.28)], startPoint: .top, endPoint: .bottom)
                        Rectangle().fill(.white).frame(height: 2)
                            .shadow(color: Theme.Colors.brand[500]!, radius: 12)
                    }
                    .frame(height: Self.height)
                    .offset(y: top)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}
