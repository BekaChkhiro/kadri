import SwiftUI
import KadriCore

/// The supplied background and detector boxes must share the same normalized frame space.
/// AR integration owns camera cropping, segmentation and calling startSteps when anchors are ready.
struct SessionScreen<Background: View>: View {
    @Bindable var model: SessionModel
    let keyframeProvider: @Sendable () async throws -> Data
    private let background: Background
    private let showsPartsOverlay: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: SessionModel, keyframeProvider: @escaping @Sendable () async throws -> Data,
         showsPartsOverlay: Bool = true, @ViewBuilder background: () -> Background) {
        self.showsPartsOverlay = showsPartsOverlay
        self.model = model
        self.keyframeProvider = keyframeProvider
        self.background = background()
    }

    var body: some View {
        ZStack {
            background.ignoresSafeArea().ignoresSafeArea(.keyboard)
            LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 150).frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea().allowsHitTesting(false)
            if showsPartsOverlay, case .parts(let result) = model.phase {
                PartsRevealView(parts: result.parts).ignoresSafeArea().ignoresSafeArea(.keyboard)
            }
            if case .scanning(let startedAt) = model.phase {
                ScanningView(startedAt: startedAt, cancel: model.cancel)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header.padding(.horizontal, 16).padding(.top, 8) }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ScrollView {
                bottomPanel.padding(.horizontal, 12).padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: phaseID)
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: model.cancel) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel("დახურვა")
            .accessibilityHint("შეწყვეტს მიმდინარე მოქმედებას")
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 14)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Theme.Colors.brand[500]!, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.instructions.isEmpty ? "კადრი" : model.instructions)
                        .font(.kadri(14, weight: .semibold)).lineLimit(1)
                    Text(model.partsResult?.object ?? "კამერით, ნაბიჯ-ნაბიჯ")
                        .font(.kadri(12)).foregroundStyle(Theme.Colors.ink[500]!).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6).padding(.trailing, 10).glass(radius: 28)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
    }

    @ViewBuilder private var bottomPanel: some View {
        switch model.phase {
        case .idle, .describing:
            DescribeBar(text: Binding(get: {
                if case .describing(let text) = model.phase { return text }
                return ""
            }, set: { text in
                if case .idle = model.phase { model.beginDescribing() }
                model.updateText(text)
            })) { model.submit(keyframeProvider: keyframeProvider) }
        case .scanning:
            EmptyView()
        case .parts(let result):
            messageCard(title: "ნაწილები ნაპოვნია", text: "\(result.object) · \(result.parts.count) ნაწილი",
                        button: "ნაბიჯების დაწყება", hint: "მოამზადებს ინსტრუქციას", action: model.startSteps)
        case .steps(let result, let steps, let streaming):
            StepCard(step: model.currentStep, parts: result.parts, index: model.currentStepIndex,
                     count: steps.count, streaming: streaming,
                     previous: model.previous, next: model.next, finish: model.finish)
        case .done:
            messageCard(title: "შესრულდა", text: "ყველა ნაბიჯი დასრულებულია.",
                        button: "ახალი სესია", hint: "ახალი პრობლემის აღწერას გახსნის", action: model.beginDescribing)
        case .error(let error, _):
            messageCard(title: "ვერ გავაგრძელე", text: error.localizedDescription,
                        button: "თავიდან", hint: "გაიმეორებს შეწყვეტილ მოთხოვნას", action: model.retry)
        }
    }

    private func messageCard(title: String, text: String, button: String, hint: String,
                             action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.kadri(21, weight: .semibold)).accessibilityAddTraits(.isHeader)
            Text(text).font(.kadri(14.5)).foregroundStyle(Theme.Colors.ink[600]!)
            Button(button, action: action).buttonStyle(SessionButtonStyle())
                .accessibilityLabel(button).accessibilityHint(hint)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .padding(16).glass()
    }

    private var phaseID: Int {
        switch model.phase {
        case .idle: 0
        case .describing: 1
        case .scanning: 2
        case .parts: 3
        case .steps: 4
        case .done: 5
        case .error: 6
        }
    }
}
