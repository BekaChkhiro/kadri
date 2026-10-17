import XCTest
import simd
@testable import KadriCore

final class FrameGeometryTests: XCTestCase {
    func testResizeAndIntrinsics() {
        XCTAssertEqual(FrameGeometry.resized(width: 1920, height: 1440), SIMD2(768, 576))
        XCTAssertEqual(FrameGeometry.resized(width: 1440, height: 1920), SIMD2(576, 768))
        let k = simd_float3x3(columns: (SIMD3(1000, 0, 0), SIMD3(0, 900, 0), SIMD3(960, 720, 1)))
        let scaled = FrameGeometry.scaledIntrinsics(k, scale: SIMD2(repeating: 0.4))
        XCTAssertEqual(scaled[0][0], 400)
        XCTAssertEqual(scaled[1][1], 360)
        XCTAssertEqual(scaled[2], SIMD3(384, 288, 1))
    }
    func testSharpVersusBlurred() {
        let width = 32
        let sharp: [UInt8] = (0..<(width * width)).map { (($0 % width / 4 + $0 / width / 4) % 2 == 0) ? 255 : 0 }
        var blurred = sharp
        for _ in 0..<12 {
            let previous = blurred
            for y in 1..<(width-1) { for x in 1..<(width-1) {
                let i = y * width + x
                let horizontal = Int(previous[i-1]) + Int(previous[i+1])
                let vertical = Int(previous[i-width]) + Int(previous[i+width])
                blurred[i] = UInt8((Int(previous[i]) + horizontal + vertical) / 5)
            }}
        }
        let high = FrameGeometry.laplacianVariance(sharp, width: width, height: width)
        let low = FrameGeometry.laplacianVariance(blurred, width: width, height: width)
        XCTAssertGreaterThan(high, low * 10)
        XCTAssertEqual(FrameGeometry.laplacianVariance(Array(repeating: 128, count: 1024), width: 32, height: 32), 0)
    }
}
