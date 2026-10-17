import XCTest
import simd
@testable import KadriCore

final class AnchorGeometryTests: XCTestCase {
    func testWorldProjectionRoundTrip() throws {
        let k = simd_float3x3(columns: (SIMD3(600, 0, 0), SIMD3(0, 610, 0), SIMD3(288, 384, 1)))
        var transform = simd_float4x4(simd_quatf(angle: 0.5, axis: SIMD3(0, 1, 0)))
        transform.columns.3 = SIMD4(1, 2, 3, 1)
        for pixel in [SIMD2<Float>(0, 0), SIMD2(288, 384), SIMD2(576, 768)] {
            let world = FrameGeometry.unproject(pixel, depth: 2, intrinsics: k, camera: transform)
            let projected = try XCTUnwrap(FrameGeometry.project(world, intrinsics: k, camera: transform))
            XCTAssertEqual(projected.x, pixel.x, accuracy: 0.001)
            XCTAssertEqual(projected.y, pixel.y, accuracy: 0.001)
        }
        XCTAssertNil(FrameGeometry.project(SIMD3(0, 0, 1), intrinsics: k, camera: matrix_identity_float4x4))
    }
    func testBoxCoordinates() {
        let size = SIMD2<Float>(576, 768)
        for point in [SIMD2<Float>(0, 0), SIMD2(250, 500), SIMD2(1000, 1000)] {
            let pixel = FrameGeometry.pixel(point, size: size)
            XCTAssertEqual(FrameGeometry.normalized(pixel, size: size), point)
        }
        XCTAssertEqual(FrameGeometry.pixel(SIMD2(250, 500), size: size), SIMD2(144, 384))
    }
    func testRobustDepth() {
        XCTAssertEqual(FrameGeometry.medianDepth([1, 1.1, 30, .nan, -1, 0]), 1.1)
        XCTAssertEqual(FrameGeometry.medianDepth([1, 2, 4, 80]), 3)
        XCTAssertNil(FrameGeometry.medianDepth([.infinity, .nan, -2]))
    }
    func testPortraitRotationMatchesSensorWorldRay() {
        let sensorK = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 900, 0), SIMD3(960, 720, 1)))
        let portraitK = simd_float3x3(columns: (SIMD3(900, 0, 0), SIMD3(0, 1000, 0), SIMD3(720, 960, 1)))
        let rotation = simd_float4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        let sensor = FrameGeometry.unproject(SIMD2(1100, 500), depth: 2, intrinsics: sensorK, camera: matrix_identity_float4x4)
        let portrait = FrameGeometry.unproject(SIMD2(940, 1100), depth: 2, intrinsics: portraitK, camera: rotation)
        XCTAssertEqual(simd_distance(sensor, portrait), 0, accuracy: 0.0001)
    }
}
