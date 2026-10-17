import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

final class MeshWrapIntegrationTests: XCTestCase {
    func testCacheReusesGeometryAndRebuildsChangedMask() async {
        let cache = TrackedMeshCache()
        let ring = [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.2),
                    CGPoint(x: 0.4, y: 0.6), CGPoint(x: 0.1, y: 0.6)]
        let box = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let contour = TrackedContour(id: "p1", polygons: [ring], referenceBox: box, maskMs: 0)
        let first = await cache.mesh(for: contour)
        let second = await cache.mesh(for: contour)
        XCTAssertEqual(first.mesh, second.mesh)
        let count = await cache.buildCount
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(first.mesh.triangleCount, 0)
        _ = await cache.mesh(for: TrackedContour(id: "p1",
            polygons: [ring.map { CGPoint(x: $0.x + 0.1, y: $0.y) }], referenceBox: box, maskMs: 0))
        let updated = await cache.buildCount
        XCTAssertEqual(updated, 2)
    }

    func testTransformMapsReferenceBoxWithoutChangingMesh() {
        let source = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let item = TrackedMesh(id: "p1", mesh: .empty, referenceBox: source)
        let target = CGRect(x: 30, y: 40, width: 120, height: 200)
        let transform = item.transform(to: target)!
        let mapped = source.applying(CGAffineTransform(scaleX: 1024, y: 1024)).applying(transform)
        XCTAssertEqual(mapped.minX, target.minX, accuracy: 0.001)
        XCTAssertEqual(mapped.maxY, target.maxY, accuracy: 0.001)
        XCTAssertEqual(mapped.width, target.width, accuracy: 0.001)
        XCTAssertNil(item.transform(to: .zero))
    }

    func testStepStateAvoidTakesPriorityAndMissingIDsStayIdle() {
        let step = Step(index: 1, title: "", text: "", focus: ["p1", "p2"], avoid: ["p2"])
        XCTAssertEqual(TrackedMesh.state(id: "p1", step: step), .focus)
        XCTAssertEqual(TrackedMesh.state(id: "p2", step: step), .avoid)
        XCTAssertEqual(TrackedMesh.state(id: "p3", step: step), .idle)
        XCTAssertEqual(TrackedMesh.state(id: "p1", step: nil), .idle)
    }
}
