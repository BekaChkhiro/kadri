import SwiftUI
import KadriCore

struct SessionFlowView: View {
    @StateObject private var dependencies = LiveSessionDependencies()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        SessionScreen(model: dependencies.model, keyframeProvider: { try await dependencies.capture() }, showsPartsOverlay: false) {
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
        if let result = dependencies.model.partsResult {
            FlowMarkersView(dependencies: dependencies, tracker: dependencies.tracker, parts: result.parts, step: dependencies.model.currentStep)
        }
    }
}

struct FlowMarkersView: View {
    @ObservedObject var dependencies: LiveSessionDependencies
    @ObservedObject var tracker: PartTracker
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
                let fallback = Self.fallbackBoxes(parts: parts, viewport: geometry.size, imageSize: dependencies.imageSize,
                                                  anchoredIDs: Set(dependencies.anchors.placements.map(\.id)))
                let boxes = PartTracker.boxes(projections).merging(fallback, uniquingKeysWith: { first, _ in first })
                let readyIDs = Set(tracker.meshes.filter { $0.mesh.triangleCount > 0 && boxes[$0.id] != nil }.map(\.id))
                ZStack(alignment: .topLeading) {
                    TrackedMeshOverlay(meshes: tracker.meshes, boxes: boxes, step: step)
                    ForEach(markers.filter { !readyIDs.contains($0.id) }) { marker in
                        Text("\(marker.name)\(marker.tracked ? "" : " · 2D")")
                            .font(.kadri(12.5, weight: .semibold)).foregroundStyle(.white)
                            .lineLimit(2).frame(width: 150)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(color(marker.tone), in: Capsule())
                            .position(x: min(max(marker.center.x, 85), max(85, geometry.size.width - 85)),
                                      y: min(max(marker.center.y, 20), max(20, geometry.size.height - 20)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    static func fallbackBoxes(parts: [Part], viewport: CGSize, imageSize: CGSize, anchoredIDs: Set<String>) -> [String: CGRect] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [:] }
        let scale = max(viewport.width/imageSize.width, viewport.height/imageSize.height)
        return Dictionary(uniqueKeysWithValues: parts.filter { $0.hasValidBox && !anchoredIDs.contains($0.id) }.map { part in
            let b = part.box
            return (part.id, CGRect(
                x: CGFloat(b[0])/1000 * imageSize.width * scale + (viewport.width-imageSize.width*scale)/2,
                y: CGFloat(b[1])/1000 * imageSize.height * scale + (viewport.height-imageSize.height*scale)/2,
                width: CGFloat(b[2]-b[0])/1000 * imageSize.width*scale,
                height: CGFloat(b[3]-b[1])/1000 * imageSize.height*scale))
        })
    }

    private func color(_ tone: FlowMarker.Tone) -> Color {
        switch tone {
        case .brand: Theme.Colors.brand[500]!
        case .danger: Color(hex: "#dc2626")
        case .neutral: Theme.Colors.ink[500]!
        }
    }
}
