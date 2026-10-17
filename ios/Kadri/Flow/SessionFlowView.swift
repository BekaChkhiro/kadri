import SwiftUI
import KadriCore

struct SessionFlowView: View {
    @StateObject private var dependencies = LiveSessionDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SessionScreen(model: dependencies.model, keyframeProvider: { try await dependencies.capture() }) {
            ARBackgroundView(controller: dependencies.controller, mockImage: dependencies.mockImage)
                .overlay { markers }
        }
        .navigationTitle("სესია")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { dependencies.controller.start() }
        .onDisappear { dependencies.stop() }
        .onChange(of: dependencies.model.phase) { _, _ in dependencies.phaseChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { dependencies.controller.start() }
            else { dependencies.stop() }
        }
    }

    @ViewBuilder private var markers: some View {
        if case .steps(let result, _, _) = dependencies.model.phase {
            FlowMarkersView(dependencies: dependencies, parts: result.parts, step: dependencies.model.currentStep)
        }
    }
}

private struct FlowMarkersView: View {
    @ObservedObject var dependencies: LiveSessionDependencies
    let parts: [Part]
    let step: Step?

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation) { _ in
                let frame = dependencies.controller.session.currentFrame
                let projections = frame.map { dependencies.anchors.projections(frame: $0, viewport: geometry.size, scale: 1) } ?? []
                let markers = FlowMarker.make(parts: parts, projections: projections,
                    fallback: dependencies.anchors.unanchoredCenters(viewport: geometry.size),
                    viewport: geometry.size, imageSize: dependencies.imageSize, step: step,
                    anchoredIDs: Set(dependencies.anchors.placements.map(\.id)))
                ZStack(alignment: .topLeading) {
                    ForEach(markers.filter { step == nil || $0.tone != .neutral }) { marker in
                        Text("\(marker.name)\(marker.tracked ? "" : " · 2D")")
                            .font(.kadri(12.5, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(2).frame(width: 150)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(color(marker.tone), in: Capsule())
                            .position(marker.center)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func color(_ tone: FlowMarker.Tone) -> Color {
        switch tone {
        case .brand: Theme.Colors.brand[500]!
        case .danger: Color(hex: "#dc2626")
        case .neutral: Theme.Colors.ink[500]!
        }
    }
}
