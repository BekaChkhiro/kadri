import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

private struct MeshFlowHost: View {
    @ObservedObject var dependencies: LiveSessionDependencies
    let photo: UIImage
    var body: some View {
        SessionScreen(model: dependencies.model, keyframeProvider: { Data() }, showsPartsOverlay: false) {
            GeometryReader { geometry in
                Image(uiImage: photo).resizable().scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay {
                        if let result = dependencies.model.partsResult {
                            FlowMarkersView(dependencies: dependencies, tracker: dependencies.tracker,
                                            parts: result.parts, step: dependencies.model.currentStep)
                        }
                    }
            }
        }
    }
}

@MainActor
final class MeshWrapIntegrationSnapshotTests: XCTestCase {
    func testLateMasksAcrossStepChanges() async throws {
        let fixture = try MeshWrapFixture.load()
        let dependencies = LiveSessionDependencies(api: MockKadriAPI())
        let model = dependencies.model
        await SessionPreviewState.parts.prepare(model)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: MeshFlowHost(dependencies: dependencies, photo: fixture.photo))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let rate = ContourDisplayRate()
        rate.start()
        defer { rate.stop(); window.isHidden = true; dependencies.tracker.stop(); model.cancel() }
        try await Task.sleep(for: .milliseconds(1200))
        print("Mesh flow simulator baseline CADisplayLink: \(rate.fps) fps")
        try capture(window, name: "parts")
        // SSE may already be displaying a step when SAM finishes.
        dependencies.phaseChanged()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(model.currentStep)
        XCTAssertTrue(dependencies.tracker.meshes.isEmpty)
        for (index, part) in MockKadriAPI.result.parts.enumerated() {
            let b = part.box
            dependencies.tracker.inject(TrackedContour(id: part.id,
                polygons: fixture.meshes[[0, 3, 4][index]].outlines.map { $0.map {
                    CGPoint(x: $0.x/fixture.photo.size.width, y: $0.y/fixture.photo.size.height)
                } },
                referenceBox: CGRect(x: CGFloat(b[0])/1000, y: CGFloat(b[1])/1000,
                                     width: CGFloat(b[2]-b[0])/1000, height: CGFloat(b[3]-b[1])/1000),
                maskMs: 0), embedMs: 0)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(3200))
        XCTAssertEqual(dependencies.tracker.meshes.count, 3)
        try capture(window, name: "avoid")
        print("Mesh flow simulator CADisplayLink: \(rate.fps) fps (3 meshes, focus+avoid)")
        XCTAssertGreaterThan(rate.fps, 20)
        model.next()
        try await Task.sleep(for: .milliseconds(450))
        try capture(window, name: "focus")
        model.previous()
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(model.currentStep?.index, 1)
    }

    private func capture(_ window: UIWindow, name: String) throws {
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/kadri-mesh-flow-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "kadri-mesh-flow-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
