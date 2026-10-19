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

final class LiveOverlayTests: XCTestCase {
    func testCadenceCountsCameraFramesInsteadOfDisplayCallbacks() {
        var cadence = LiveOverlayCadence()
        cadence.presented(frame: nil, now: 0)
        // A 120 Hz display presents a 60 Hz camera, each frame twice.
        for tick in 0..<120 {
            cadence.presented(frame: Double(tick/2)/60, now: Double(tick+1)/120)
        }
        XCTAssertEqual(cadence.fps, 60, accuracy: 0.001)
        // Repeated callbacks for a frozen frame must not claim 60 fps.
        for tick in 1...120 {
            cadence.presented(frame: 59.0/60, now: 1+Double(tick)/120)
        }
        XCTAssertEqual(cadence.fps, 0)
    }

    func testCadenceRejectsFutureStaleAndMissingFrames() {
        var cadence = LiveOverlayCadence()
        cadence.presented(frame: 10, now: 0)
        cadence.presented(frame: 0, now: 0.8)
        cadence.presented(frame: nil, now: 1)
        XCTAssertEqual(cadence.fps, 0)
        cadence.presented(frame: 1.5, now: 1.5)
        cadence.presented(frame: 1.5, now: 1.6)
        cadence.presented(frame: nil, now: 2)
        XCTAssertEqual(cadence.fps, 1)
    }

    func testAcceptedShapeBlendsWhileCameraMotionRemainsImmediate() throws {
        let old = [LiveContourWarp.corners(CGRect(x: 0, y: 0, width: 1, height: 1))]
        let new = old.map { $0.map { CGPoint(x: $0.x+0.1, y: $0.y) } }
        let blend = try XCTUnwrap(LiveContourBlend(from: old, to: new, startedAt: 10))
        XCTAssertEqual(blend.value(at: 10), old)
        XCTAssertEqual(blend.value(at: 11), new)
        let half = blend.value(at: 10.09)
        XCTAssertEqual(half[0][0].x, 0.05, accuracy: 1e-6)
        let firstPose = try XCTUnwrap(LiveContourWarp(quad: LiveContourWarp.corners(CGRect(x: 0, y: 0, width: 100, height: 100))))
        let movedPose = try XCTUnwrap(LiveContourWarp(quad: LiveContourWarp.corners(CGRect(x: 40, y: 0, width: 100, height: 100))))
        let a = try XCTUnwrap(firstPose.polygons(half))
        let b = try XCTUnwrap(movedPose.polygons(half))
        XCTAssertEqual(b[0][0].x-a[0][0].x, 40, accuracy: 1e-6)
        XCTAssertNil(LiveContourBlend(from: old, to: [], startedAt: 10))
    }

    @MainActor func testPinAndContourMoveTogetherWithoutSwiftUIOrSAMRefresh() throws {
        let view = LiveCameraOverlayView(frame: CGRect(x: 0, y: 0, width: 380, height: 380))
        view.backgroundColor = .darkGray
        let identity = CGRect(x: 0, y: 0, width: 1, height: 1)
        func draw(offset: CGFloat) {
            let quad = [CGPoint(x: 60+offset, y: 60), CGPoint(x: 260+offset, y: 90),
                        CGPoint(x: 280+offset, y: 260), CGPoint(x: 40+offset, y: 230)]
            let projection = PartProjection(id: "p1", center: CGPoint(x: 160+offset, y: 150),
                                            corners: quad, returnErrorPixels: nil)
            let contour = TrackedContour(id: "p1", polygons: [quad], referenceBox: identity, maskMs: 0)
            view.apply(projections: [projection], contours: [contour], labels: ["p1": "კლავიატურა"], selectedID: "p1")
            view.layoutIfNeeded()
        }
        draw(offset: 0)
        let first = try XCTUnwrap(view.subviews.first { $0 is UIControl })
        for offset in 1...40 { draw(offset: CGFloat(offset)) }
        let last = try XCTUnwrap(view.subviews.first { $0 is UIControl })
        XCTAssertTrue(first === last, "Camera motion must reuse the marker, not rebuild a SwiftUI button")
        XCTAssertEqual(last.center.x, 200)
        XCTAssertTrue(last.accessibilityTraits.contains(.selected))
        let layerView = try XCTUnwrap(view.subviews.first { $0 is ContourLayerView })
        let path = try XCTUnwrap((layerView.layer.sublayers?.first as? CAShapeLayer)?.path)
        XCTAssertEqual(path.boundingBoxOfPath.minX, 80, accuracy: 1e-6)
        let image = UIGraphicsImageRenderer(size: view.bounds.size).image { view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = "live-overlay-pin-and-contour"
        attachment.lifetime = .keepAlways; add(attachment)
        view.apply(projections: [], contours: [], labels: [:], selectedID: nil)
        XCTAssertTrue(view.subviews.filter { $0 is UIControl }.isEmpty)
        XCTAssertTrue(layerView.layer.sublayers?.isEmpty ?? true)
    }

    @MainActor func testNoAcceptedRefreshReportsUnknownAgeAndStopClearsContours() {
        let tracker = LiveContourTracker()
        XCTAssertEqual(tracker.refreshAgeMilliseconds(now: 100), -1)
        tracker.stop()
        XCTAssertEqual(tracker.refreshAgeMilliseconds(now: 200), -1)
        XCTAssertTrue(tracker.contours.isEmpty)
    }
}
