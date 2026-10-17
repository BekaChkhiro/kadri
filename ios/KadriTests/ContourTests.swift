import XCTest
import KadriCore
@testable import Kadri

final class ContourTests: XCTestCase {
    private func mask(width: Int, height: Int, pixels: [UInt8]) -> Mask {
        Mask(width: width, height: height, pixels: pixels, score: 1, scores: [1], selected: 0, decodeMs: 0, postMs: 0)
    }

    func testCircleAndTopLeftCoordinates() throws {
        let width = 384, height = 768
        let center = CGPoint(x: 110, y: 200), radius: CGFloat = 70
        let pixels: [UInt8] = (0..<(width*height)).map { i in
            hypot(CGFloat(i%width)-center.x, CGFloat(i/width)-center.y) <= radius ? 255 : 0
        }
        let polygons = try MaskContours.extract(mask(width: width, height: height, pixels: pixels))
        XCTAssertEqual(polygons.count, 1)
        let polygon = try XCTUnwrap(polygons.first)
        XCTAssertGreaterThan(polygon.count, 8)
        XCTAssertLessThan(polygon.count, 60)
        for p in polygon {
            XCTAssertEqual(hypot(p.x*CGFloat(width)-center.x, p.y*CGFloat(height)-center.y), radius, accuracy: 2)
        }
    }

    func testLargestTwoComponentsAndEmptyMask() throws {
        let width = 768
        var pixels = [UInt8](repeating: 0, count: width*width)
        for (x, y, side) in [(50, 50, 100), (300, 300, 80), (600, 600, 20)] {
            for j in y..<(y+side) { for i in x..<(x+side) { pixels[j*width+i] = 255 } }
        }
        let contours = try MaskContours.extract(mask(width: width, height: width, pixels: pixels))
        XCTAssertEqual(contours.count, 2)
        XCTAssertGreaterThan(ContourGeometry.area(contours[0]), ContourGeometry.area(contours[1]))
        XCTAssertTrue(contours.flatMap { $0 }.allSatisfy { $0.x < 0.6 && $0.y < 0.6 })
        XCTAssertTrue(try MaskContours.extract(mask(width: 16, height: 16, pixels: .init(repeating: 0, count: 256))).isEmpty)
    }

    func testSinkCPUInferenceContourBoundary() async throws {
        struct Scene: Decodable {
            struct Part: Decodable { let box: [Int] }
            let parts: [Part]
        }
        let root = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Fixtures", withExtension: nil))
            .appendingPathComponent("sink")
        let scene = try JSONDecoder().decode(Scene.self, from: Data(contentsOf: root.appendingPathComponent("boxes.json")))
        let image = try SegmentationImage.load(root.appendingPathComponent("input.png"))
        let segmenter = try Segmenter(computeUnits: .cpuOnly)
        let embedding = try await segmenter.embed(image)
        let result = try await segmenter.mask(embedding: embedding, box: PartBox(scene.parts[0].box))
        let started = Clock.now
        let polygons = try MaskContours.extract(result)
        let contourMs = Clock.ms(since: started)
        XCTAssertFalse(polygons.isEmpty)
        // Boundary pixels have at least one 4-neighbour outside the foreground.
        var boundary: [CGPoint] = []
        for y in 0..<result.height { for x in 0..<result.width where result.pixels[y*result.width+x] > 0 {
            let neighbours = [(x-1,y), (x+1,y), (x,y-1), (x,y+1)]
            if neighbours.contains(where: { nx, ny in
                nx < 0 || ny < 0 || nx >= result.width || ny >= result.height || result.pixels[ny*result.width+nx] == 0
            }) { boundary.append(CGPoint(x: x, y: y)) }
        }}
        XCTAssertFalse(boundary.isEmpty)
        var maximum: CGFloat = 0
        for point in polygons.flatMap({ $0 }) {
            let p = CGPoint(x: point.x*CGFloat(result.width), y: point.y*CGFloat(result.height))
            let distance = boundary.map { hypot($0.x-p.x, $0.y-p.y) }.min()!
            maximum = max(maximum, distance)
        }
        XCTAssertLessThanOrEqual(maximum, 2)
        print(String(format: "CONTOUR-SINK CPU embed %.1f ms mask %.1f ms contour %.1f ms maxBoundary %.3f px vertices %d",
                     embedding.preMs + embedding.encodeMs, result.decodeMs + result.postMs, contourMs, maximum,
                     polygons.reduce(0) { $0 + $1.count }))
    }
}
