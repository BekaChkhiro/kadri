import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class PhotoSnapshotTests: XCTestCase {
    func testPhotoStepsAndWaiting() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"))
        let photo = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let result = MockKadriAPI.result
        let meshes = result.parts.map { part in
            let b = part.box.map { CGFloat($0) / 1000 }
            let rect = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            let polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                .map { CGPoint(x: $0.x * 1024, y: $0.y * 1024) }
            return TrackedMesh(id: part.id, mesh: MeshTriangulation.triangulate(polygons: [polygon]), referenceBox: rect)
        }
        let directory = URL(fileURLWithPath: "/tmp/kadri-photo-shots-v3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 0...6 {
            let waiting = index == 5
            let completed = index == 6
            let stepIndex = min(index, MockKadriAPI.sampleSteps.count - 1)
            let screen = PhotoResultView(image: photo, parts: result.parts, meshes: waiting ? [] : meshes,
                step: waiting ? nil : MockKadriAPI.sampleSteps[stepIndex], index: waiting ? 0 : stepIndex,
                count: waiting ? 0 : MockKadriAPI.sampleSteps.count, streaming: waiting, object: result.object,
                segmentationStatus: waiting ? "ვასკანერებ…" : nil,
                close: {}, previous: {}, next: {}, finish: {}, completed: completed)
                .environment(\.meshWrapReduceMotion, true)
            let host = UIHostingController(rootView: screen)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(1500))
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let data = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(data.count, 1000)
            let name = completed ? "done" : waiting ? "waiting" : index == 4 ? "step-last" : "step-\(index + 1)"
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
    }
}
