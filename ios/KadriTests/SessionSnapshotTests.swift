import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class SessionSnapshotTests: XCTestCase {
    func testHostAllSessionPhases() async throws {
        let photoURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Camera/assets/sink-trap.png")
        let photo = try XCTUnwrap(UIImage(contentsOfFile: photoURL.path))
        for state in SessionPreviewState.allCases {
            let model = state.makeModel()
            await state.prepare(model)
            let screen = SessionScreen(model: model, keyframeProvider: { Data() }) {
                GeometryReader { geometry in
                    Image(uiImage: photo).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }
            let host = UIHostingController(rootView: screen)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
            var rendered = false
            let image = renderer.image { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            XCTAssertTrue(rendered, "Window hierarchy must render")
            let data = try XCTUnwrap(image.pngData())
            let path = "/tmp/kadri-session-\(state.rawValue).png"
            try data.write(to: URL(fileURLWithPath: path))
            let attachment = XCTAttachment(image: image)
            attachment.name = "kadri-session-\(state.rawValue)"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(data.count, 1000)
            window.isHidden = true
            model.cancel()
        }
    }
}
