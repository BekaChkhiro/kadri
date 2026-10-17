import XCTest
import ARKit
@testable import Kadri

final class TouchSegmentationTests: XCTestCase {
    func testPortraitScreenMappingAndAspectFill() throws {
        let image = CGSize(width: 512, height: 768)
        // Sensor -> portrait: (x,y) -> (1-y,x).
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let full = CGSize(width: 256, height: 384)
        let p = try XCTUnwrap(TouchGeometry.pixel(CGPoint(x: 64, y: 96), viewport: full,
                                                imageSize: image, displayTransform: rotation))
        XCTAssertEqual(p.x, 128, accuracy: 1e-6); XCTAssertEqual(p.y, 192, accuracy: 1e-6)
        // A square viewport crops the top/bottom of the portrait frame, leaving y=128...640.
        let crop = CGAffineTransform(a: 1, b: 0, c: 0, d: 1.5, tx: 0, ty: -0.25)
        let square = CGSize(width: 512, height: 512)
        let display = rotation.concatenating(crop)
        let top = try XCTUnwrap(TouchGeometry.pixel(CGPoint(x: 256, y: 0), viewport: square,
                                                  imageSize: image, displayTransform: display))
        XCTAssertEqual(top.x, 256, accuracy: 1e-6); XCTAssertEqual(top.y, 128, accuracy: 1e-6)
        let reference = PartReference(size: image, cameraTransform: matrix_identity_float4x4, intrinsics: matrix_identity_float3x3)
        XCTAssertEqual(reference.displayPoint(top, viewport: square).y, 0, accuracy: 1e-6)
        XCTAssertNil(TouchGeometry.pixel(CGPoint(x: -1, y: 0), viewport: square, imageSize: image, displayTransform: display))
        XCTAssertNil(TouchGeometry.pixel(.zero, viewport: .zero, imageSize: image, displayTransform: display))
        XCTAssertNil(TouchGeometry.pixel(.zero, viewport: square, imageSize: image, displayTransform: .init(scaleX: 0, y: 0)))
    }

    func testMaskBoundsRoundOutwardsAndEmptyMask() {
        func mask(_ pixels: [UInt8]) -> Mask {
            Mask(width: 3, height: 2, pixels: pixels, score: 1, scores: [1], selected: 0, decodeMs: 0, postMs: 0)
        }
        let selected = mask([0, 255, 0, 0, 255, 0])
        XCTAssertEqual(TouchGeometry.bounds(selected)?.values, [333, 0, 667, 1000])
        XCTAssertEqual(TouchGeometry.samples(selected), [CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)])
        XCTAssertNil(TouchGeometry.bounds(mask([0, 0, 0, 0, 0, 0])))
    }

    @MainActor func testAppendRemoveClearIncludingPendingSessionAnchors() {
        let store = PartAnchors(), session = ARSession()
        let intrinsics = simd_float3x3(columns: (SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(50, 50, 1)))
        let reference = PartReference(size: CGSize(width: 100, height: 100), cameraTransform: matrix_identity_float4x4,
                                      intrinsics: intrinsics, depth: 2)
        store.append(reference: reference, parts: [("t1", [250, 250, 750, 750])], session: session)
        store.append(reference: reference, parts: [("t2", [100, 100, 300, 300])], session: session)
        XCTAssertEqual(store.placements.map(\.id), ["t1", "t2"])
        XCTAssertEqual(store.placements[0].worldPosition.z, -2, accuracy: 1e-6)
        XCTAssertEqual(store.placements[0].worldPosition.x, 0, accuracy: 1e-6)
        store.append(reference: reference, parts: [("t1", [0, 0, 100, 100])], session: session)
        XCTAssertEqual(store.placements.count, 2, "Duplicate IDs preserve existing placement")
        store.remove(id: "t1", session: session)
        XCTAssertEqual(store.placements.map(\.id), ["t2"])
        XCTAssertNil(store.anchorIDs["t1"])
        store.remove(id: "absent", session: session)
        store.clear(session: session)
        XCTAssertTrue(store.placements.isEmpty); XCTAssertTrue(store.anchorIDs.isEmpty); XCTAssertTrue(store.unanchored.isEmpty)
        store.append(reference: reference, parts: [("t3", [0, 0, 0, 0])], session: session)
        XCTAssertEqual(store.unanchored, ["t3"])
        store.remove(id: "t3", session: session)
        XCTAssertTrue(store.unanchored.isEmpty)
    }

    @MainActor func testInjectionPreservesOtherContoursAndStopClears() {
        let tracker = PartTracker()
        for id in ["t1", "t2"] {
            tracker.inject(TrackedContour(id: id, polygons: [[.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)]],
                                          referenceBox: CGRect(x: 0, y: 0, width: 1, height: 1), maskMs: 12), embedMs: 40)
        }
        XCTAssertEqual(tracker.contours.map(\.id), ["t1", "t2"])
        XCTAssertEqual(tracker.embedMs, 40)
        tracker.stop()
        XCTAssertTrue(tracker.contours.isEmpty)
    }
}

final class TouchSegmentationParityTests: XCTestCase {
    func testAllFivePointReferencesAndThreePartQualityGate() async throws {
        struct Report: Decodable {
            struct Part: Decodable { let id: String; let point: [Int] }
            let parts: [Part]
        }
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("sink")
        let report = try JSONDecoder().decode(Report.self, from: Data(contentsOf: root.appendingPathComponent("point_results.json")))
        let segmenter = try Segmenter(computeUnits: .cpuOnly)
        let start = Clock.now
        let embedding = try await segmenter.embed(SegmentationImage.load(root.appendingPathComponent("input.png")))
        print("TOUCH embed_ms=\(Clock.ms(since: start))")
        func pixels(_ name: String) throws -> [UInt8] {
            let image = try SegmentationImage.load(root.appendingPathComponent(name))
            let rgb = try Segmenter.rgbxBytes(image)
            return stride(from: 0, to: rgb.count, by: 4).map { rgb[$0] }
        }
        var passed = 0
        for part in report.parts {
            let mask = try await segmenter.maskFromPoint(embedding: embedding, point: CGPoint(x: part.point[0], y: part.point[1]))
            let parity = maskIoU(mask.pixels, try pixels("point_coreml_\(part.id).png"))
            let quality = maskIoU(mask.pixels, try pixels("sam2_\(part.id).png"))
            let contourStart = Clock.now
            XCTAssertFalse(try MaskContours.extract(mask).isEmpty)
            let contourMs = Clock.ms(since: contourStart)
            print("TOUCH \(part.id) parity=\(parity) sam2=\(quality) decode_ms=\(mask.decodeMs) post_ms=\(mask.postMs) contour_ms=\(contourMs)")
            XCTAssertGreaterThanOrEqual(parity, 0.95, part.id)
            if ["p1", "p4", "p5"].contains(part.id) { XCTAssertGreaterThanOrEqual(quality, 0.7, part.id); passed += 1 }
        }
        XCTAssertEqual(passed, 3)
        do {
            _ = try await segmenter.maskFromPoint(embedding: embedding, point: CGPoint(x: -1, y: 1))
            XCTFail("Invalid point accepted")
        } catch { }
    }
}
