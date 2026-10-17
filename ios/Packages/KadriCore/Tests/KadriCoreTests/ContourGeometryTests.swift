import XCTest
@testable import KadriCore

final class ContourGeometryTests: XCTestCase {
    func testClosedSimplificationPreservesShapeWithinTolerance() {
        let circle = (0..<360).map { i in
            let angle = Double(i) * .pi / 180
            return CGPoint(x: 100 + 80*cos(angle), y: 100 + 80*sin(angle))
        }
        let simple = ContourGeometry.simplify(circle + [circle[0]], tolerance: 1.5)
        XCTAssertGreaterThan(simple.count, 8)
        XCTAssertLessThan(simple.count, 40)
        for p in circle {
            let distance = simple.indices.map { ContourGeometry.segmentDistance(p, simple[$0], simple[($0+1)%simple.count]) }.min()!
            XCTAssertLessThanOrEqual(distance, 1.5)
        }
        XCTAssertGreaterThan(ContourGeometry.area(simple), .pi * 80 * 80 * 0.97)
    }

    func testBoxTransformAndInverse() throws {
        let a = CGRect(x: 0.2, y: 0.3, width: 0.4, height: 0.2)
        let b = CGRect(x: 30, y: 80, width: 200, height: 140)
        let transform = try XCTUnwrap(ContourGeometry.transform(from: a, to: b))
        for point in [a.origin, CGPoint(x: a.midX, y: a.midY), CGPoint(x: a.maxX, y: a.maxY)] {
            let restored = point.applying(transform).applying(transform.inverted())
            XCTAssertEqual(restored.x, point.x, accuracy: 1e-8)
            XCTAssertEqual(restored.y, point.y, accuracy: 1e-8)
        }
        let center = CGPoint(x: a.midX, y: a.midY).applying(transform)
        XCTAssertEqual(center.x, b.midX, accuracy: 1e-8)
        XCTAssertEqual(center.y, b.midY, accuracy: 1e-8)
        XCTAssertNil(ContourGeometry.transform(from: .zero, to: b))
        XCTAssertNil(ContourGeometry.transform(from: a, to: .null))
    }

    func testResegmentThresholdAndInterval() {
        let box = CGRect(x: 100, y: 100, width: 100, height: 200)
        XCTAssertFalse(ContourGeometry.shouldResegment(frames: 29, reference: box, current: box))
        XCTAssertTrue(ContourGeometry.shouldResegment(frames: 30, reference: box, current: box))
        XCTAssertFalse(ContourGeometry.shouldResegment(frames: 30, interval: 60, reference: box, current: box))
        XCTAssertFalse(ContourGeometry.shouldResegment(frames: 1, reference: box, current: box.offsetBy(dx: 20, dy: 40)))
        XCTAssertTrue(ContourGeometry.shouldResegment(frames: 1, reference: box, current: box.offsetBy(dx: 21, dy: 0)))
        XCTAssertTrue(ContourGeometry.shouldResegment(frames: 1, reference: box, current: box.offsetBy(dx: 0, dy: 41)))
        XCTAssertTrue(ContourGeometry.shouldResegment(frames: 1, reference: box, current: box.insetBy(dx: -11, dy: 0)))
        XCTAssertFalse(ContourGeometry.shouldResegment(frames: 30, reference: .zero, current: box))
    }
}
