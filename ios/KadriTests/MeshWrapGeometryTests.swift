import XCTest
import QuartzCore
import KadriCore
@testable import Kadri

final class MeshWrapGeometryTests: XCTestCase {
    func testSinkMaskGeometryAndBuildBudget() throws {
        let directory = try XCTUnwrap(Bundle.main.url(forResource: "sink",withExtension: nil))
        for index in 1...5 {
            let image = try SegmentationImage.load(directory.appendingPathComponent("coreml_p\(index).png"))
            var pixels = [UInt8](repeating: 0,count: image.width*image.height)
            let decoded = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress,width: image.width,height: image.height,
                                              bitsPerComponent: 8,bytesPerRow: image.width,
                                              space: CGColorSpaceCreateDeviceGray(),bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.draw(image,in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
                return true
            }
            XCTAssertTrue(decoded)
            var timings: [Double] = []
            var mesh = TriangulatedMesh.empty
            for _ in 0..<21 {
                let start = CACurrentMediaTime()
                mesh = MeshTriangulation.triangulate(width: image.width,height: image.height,pixels: pixels)
                timings.append((CACurrentMediaTime()-start)*1000)
            }
            let median = timings.dropFirst().sorted()[10]
            print("MeshWrap sink p\(index): \(mesh.triangleCount) triangles / \(mesh.vertices.count) vertices, mask+grid median \(median) ms")
            XCTAssertGreaterThan(mesh.triangleCount,0)
            XCTAssertLessThanOrEqual(mesh.triangleCount,600)
            XCTAssertLessThanOrEqual(median,5,"Complete bitmap→mesh budget, p\(index)")
            for i in stride(from: 0,to: mesh.triangleIndices.count,by: 3) {
                let points = mesh.triangleIndices[i..<i+3].map { mesh.vertices[$0] }
                let x = points.reduce(0) { $0+$1.x }/3, y = points.reduce(0) { $0+$1.y }/3
                XCTAssertGreaterThan(pixels[Int(y)*image.width+Int(x)],127)
            }
        }
    }
}
