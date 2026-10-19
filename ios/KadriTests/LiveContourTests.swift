import XCTest
import UIKit
@testable import Kadri

final class LiveContourTests: XCTestCase {
    private let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private func ring(_ rect: CGRect) -> [CGPoint] { LiveContourWarp.corners(rect) }

    func testPerspectiveWarpMapsAllCornersAndRoundTripsInterior() throws {
        let quad = [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.8, y: 0.2),
                    CGPoint(x: 0.95, y: 0.9), CGPoint(x: 0.05, y: 0.8)]
        let warp = try XCTUnwrap(LiveContourWarp(quad: quad))
        for (input, output) in zip(ring(unit), quad) {
            let p = try XCTUnwrap(warp.apply(input))
            XCTAssertEqual(p.x, output.x, accuracy: 1e-8)
            XCTAssertEqual(p.y, output.y, accuracy: 1e-8)
        }
        let center = try XCTUnwrap(warp.apply(CGPoint(x: 0.5, y: 0.5)))
        // Perspective has a non-affine vertical component for this trapezoid.
        XCTAssertGreaterThan(abs(center.y - 0.5), 0.01)
        let returned = try XCTUnwrap(warp.apply(center, inverse: true))
        XCTAssertEqual(returned.x, 0.5, accuracy: 1e-8)
        XCTAssertEqual(returned.y, 0.5, accuracy: 1e-8)
    }

    func testWarpRejectsDegenerateCrossedAndNonfiniteQuads() {
        XCTAssertNil(LiveContourWarp(quad: [.zero, .zero, .zero, .zero]))
        XCTAssertNil(LiveContourWarp(quad: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
                                          CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1)]))
        XCTAssertNil(LiveContourWarp(quad: [CGPoint(x: CGFloat.nan, y: 0)] + Array(ring(unit).dropFirst())))
    }

    func testRasterIoUAndEmptyMasks() {
        let a = [ring(CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4))]
        let b = [ring(CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.4))]
        XCTAssertEqual(LiveContourGeometry.iou(a, a), 1)
        XCTAssertEqual(LiveContourGeometry.iou(a, b), 1.0/3, accuracy: 0.02)
        XCTAssertEqual(LiveContourGeometry.iou(a, [ring(CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1))]), 0)
        XCTAssertEqual(LiveContourGeometry.iou([], []), 0)
    }

    func testRefreshGateUsesCapturePoseAndPreservesOldShapeOnRejection() throws {
        let old = [LiveContourGeometry.resample(ring(unit))]
        let quad = [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.8, y: 0.2),
                    CGPoint(x: 0.9, y: 0.9), CGPoint(x: 0.1, y: 0.8)]
        let warp = try XCTUnwrap(LiveContourWarp(quad: quad))
        let candidate = try XCTUnwrap(warp.polygons(old))
        let accepted = try XCTUnwrap(LiveContourGeometry.accept(previous: old, candidate: candidate, captureWarp: warp))
        for (a, b) in zip(old[0], accepted[0]) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
        let rejected = LiveContourGeometry.accept(previous: old,
            candidate: [ring(CGRect(x: 0.01, y: 0.01, width: 0.03, height: 0.03))], captureWarp: warp)
        XCTAssertNil(rejected)
        XCTAssertEqual(rejected ?? old, old)
        XCTAssertNil(LiveContourGeometry.accept(previous: old, candidate: [], captureWarp: warp))
    }

    func testSmoothingAlignsCyclicVerticesAndWindingWithoutShrinking() throws {
        let old = LiveContourGeometry.resample(ring(unit))
        let reversed = Array((Array(old[17...]) + Array(old[..<17])).reversed())
        let result = try XCTUnwrap(LiveContourGeometry.smooth(old: [old], new: [reversed]))[0]
        for (a, b) in zip(old, result) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
        }
    }

    func testRefreshThresholdRejectsLargeShapeChanges() throws {
        let previous = [LiveContourGeometry.resample(ring(unit))]
        let warp = try XCTUnwrap(LiveContourWarp(quad: ring(CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8))))
        let close = try XCTUnwrap(warp.polygons([ring(CGRect(x: 0, y: 0, width: 0.65, height: 1))]))
        let distant = try XCTUnwrap(warp.polygons([ring(CGRect(x: 0, y: 0, width: 0.55, height: 1))]))
        XCTAssertNotNil(LiveContourGeometry.accept(previous: previous, candidate: close, captureWarp: warp))
        XCTAssertNil(LiveContourGeometry.accept(previous: previous, candidate: distant, captureWarp: warp))
    }

    func testShapeEMAOnlyMovesPartwayAndRejectsTopologyChanges() throws {
        let old = LiveContourGeometry.resample(ring(unit))
        let shifted = old.map { CGPoint(x: $0.x+0.1, y: $0.y) }
        let result = try XCTUnwrap(LiveContourGeometry.smooth(old: [old], new: [shifted], alpha: 0.2))[0]
        let meanShift = zip(old, result).reduce(CGFloat.zero) { $0 + $1.1.x - $1.0.x } / CGFloat(old.count)
        XCTAssertEqual(meanShift, 0.02, accuracy: 1e-6)
        XCTAssertNil(LiveContourGeometry.smooth(old: [old], new: [shifted, shifted]))
    }

    func testCanonicalShapeProjectsWithCurrentPoseWithoutAccumulatingDrift() throws {
        let old = [LiveContourGeometry.resample(ring(unit))]
        let a = try XCTUnwrap(LiveContourWarp(quad: ring(CGRect(x: 10, y: 20, width: 200, height: 100))))
        let b = try XCTUnwrap(LiveContourWarp(quad: ring(CGRect(x: 40, y: 50, width: 200, height: 100))))
        let initial = try XCTUnwrap(a.polygons(old))
        let moved = try XCTUnwrap(b.polygons(old))
        XCTAssertEqual(moved[0][0].x-initial[0][0].x, 30, accuracy: 1e-8)
        XCTAssertEqual(a.polygons(old), initial)
    }

    @MainActor func testProjectedContourRendersThroughExistingLayerWithoutSecondTransform() throws {
        let quad = [CGPoint(x: 80, y: 70), CGPoint(x: 300, y: 110),
                    CGPoint(x: 340, y: 310), CGPoint(x: 40, y: 270)]
        let warp = try XCTUnwrap(LiveContourWarp(quad: quad))
        let polygons = try XCTUnwrap(warp.polygons([ring(unit)]))
        let contour = TrackedContour(id: "keyboard", polygons: polygons, referenceBox: unit, maskMs: 0)
        let view = ContourLayerView(frame: CGRect(x: 0, y: 0, width: 380, height: 380))
        view.backgroundColor = .darkGray
        view.update(contours: [contour], boxes: [contour.id: unit], focus: [contour.id], avoid: [])
        let shape = try XCTUnwrap(view.layer.sublayers?.first as? CAShapeLayer)
        let path = try XCTUnwrap(shape.path)
        XCTAssertEqual(path.boundingBoxOfPath.minX, 40, accuracy: 1e-6)
        XCTAssertEqual(path.boundingBoxOfPath.maxX, 340, accuracy: 1e-6)
        // A point inside the axis-aligned box but outside the actual trapezoid stays outside.
        XCTAssertFalse(path.contains(CGPoint(x: 45, y: 75)))
        XCTAssertTrue(path.contains(CGPoint(x: 190, y: 190)))
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "live-perspective-contour"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
