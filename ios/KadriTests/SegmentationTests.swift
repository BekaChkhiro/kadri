import CoreGraphics
import CoreML
import XCTest
@testable import Kadri

private struct FixtureScene: Decodable {
    struct Part: Decodable {
        let id: String
        let name: String
        let box: [Int]
        let boxPixels: [Float]
        let promptBox: [Float]
        let selected: Int
        let scores: [Float]
    }
    let scene: String
    let width: Int
    let height: Int
    let parts: [Part]
}

private enum Fixtures {
    static let root = Bundle(for: SegmentationPreprocessingTests.self).url(forResource: "Fixtures", withExtension: nil)!

    static func scene(_ name: String) throws -> FixtureScene {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FixtureScene.self,
                                  from: Data(contentsOf: root.appendingPathComponent("\(name)/boxes.json")))
    }

    static func image(_ scene: String) throws -> CGImage {
        try SegmentationImage.load(root.appendingPathComponent("\(scene)/input.png"))
    }

    /// 0/255 grayscale PNG → one byte per pixel.
    static func mask(_ scene: String, _ file: String) throws -> (width: Int, height: Int, pixels: [UInt8]) {
        let image = try SegmentationImage.load(root.appendingPathComponent("\(scene)/\(file).png"))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                                    bitsPerComponent: 8, bytesPerRow: image.width,
                                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return (image.width, image.height, pixels)
    }
}

func maskIoU(_ a: [UInt8], _ b: [UInt8]) -> Double {
    precondition(a.count == b.count)
    var inter = 0, union = 0
    for i in 0..<a.count {
        let x = a[i] > 127, y = b[i] > 127
        if x && y { inter += 1 }
        if x || y { union += 1 }
    }
    return union == 0 ? 1 : Double(inter) / Double(union)
}

final class SegmentationPreprocessingTests: XCTestCase {
    func testPromptBoxMatchesPythonForEveryFixturePart() throws {
        for name in ["sink", "car", "gym"] {
            let scene = try Fixtures.scene(name)
            for part in scene.parts {
                let box = try PartBox(part.box)
                XCTAssertEqual(SAMGeometry.boxPixels(box, width: scene.width, height: scene.height), part.boxPixels,
                               "\(name)/\(part.id)")
                XCTAssertEqual(try SAMGeometry.promptBox(box, width: scene.width, height: scene.height),
                               part.promptBox, "\(name)/\(part.id)")
            }
        }
    }

    func testPromptBoxRoundsOutwardsThenScalesPerAxis() throws {
        // 512×768: x 101*0.512 = 51.712 → 51, y 333*0.768 = 255.744 → 255, ceil(512*0.9) = 461, ceil(768*0.5) = 384.
        let box = try SAMGeometry.promptBox(PartBox(x0: 101, y0: 333, x1: 900, y1: 500), width: 512, height: 768)
        XCTAssertEqual(box, [51 * 2, 255 * Float(1024.0 / 768.0), 461 * 2, 384 * Float(1024.0 / 768.0)])
        XCTAssertEqual(try SAMGeometry.promptBox(PartBox(x0: 0, y0: 0, x1: 1000, y1: 1000), width: 432, height: 768),
                       [0, 0, 1024, 1024])
    }

    func testInvalidBoxesThrow() {
        for values in [[0, 0, 0, 10], [10, 20, 5, 30], [0, 0, 1001, 10], [-1, 0, 10, 10], [10, 10, 20, 10]] {
            XCTAssertThrowsError(try SAMGeometry.promptBox(PartBox(values), width: 100, height: 100), "\(values)")
        }
        XCTAssertThrowsError(try PartBox([1, 2, 3]))
        XCTAssertThrowsError(try SAMGeometry.promptBox(PartBox(x0: 0, y0: 0, x1: 10, y1: 10), width: 0, height: 10))
    }

    func testResizeSourceCoordinates() {
        // Upscale 768 → 1024: centres map to (d + 0.5) * 0.75 - 0.5.
        XCTAssertEqual(SAMResample.sourceCoordinate(0, sourceSize: 768, destinationSize: 1024), -0.125)
        XCTAssertEqual(SAMResample.sourceCoordinate(1023, sourceSize: 768, destinationSize: 1024), 767.125)
        XCTAssertEqual(SAMResample.sourceCoordinate(0, sourceSize: 256, destinationSize: 512), -0.25)
        let taps = SAMResample.linearTaps(source: 768, destination: 1024)
        XCTAssertEqual(taps.i0.first, 0)
        XCTAssertEqual(taps.w1.first, 0)  // clamped at 0
        XCTAssertEqual(taps.i0.last, 767)
        XCTAssertEqual(taps.i1.last, 767)  // second tap clamps at the border
    }

    func testBilinearTwoToFour() {
        let src: [Float] = [0, 10]
        var dst = [Float](repeating: -1, count: 4)
        SAMResample.bilinear(src, width: 2, height: 1, into: &dst, width: 4, height: 1)
        XCTAssertEqual(dst, [0, 2.5, 7.5, 10])
    }

    func testResamplingMatchesPyTorch() throws {
        struct Case: Decodable {
            let mode: String
            let src_w: Int, src_h: Int, dst_w: Int, dst_h: Int
            let src: [Float], dst: [Float]
        }
        let cases = try JSONDecoder().decode([Case].self,
                                             from: Data(contentsOf: Fixtures.root.appendingPathComponent("interp.json")))
        XCTAssertEqual(Set(cases.map(\.mode)), ["bilinear", "bicubic"])
        for c in cases {
            var out = [Float](repeating: .nan, count: c.dst_w * c.dst_h)
            if c.mode == "bicubic" {
                SAMResample.bicubic(c.src, width: c.src_w, height: c.src_h, into: &out, width: c.dst_w, height: c.dst_h)
            } else {
                SAMResample.bilinear(c.src, width: c.src_w, height: c.src_h, into: &out, width: c.dst_w, height: c.dst_h)
            }
            let error = zip(out, c.dst).map { abs($0 - $1) }.max() ?? .nan
            XCTAssertLessThan(error, 1e-5, "\(c.mode) \(c.src_w)x\(c.src_h)→\(c.dst_w)x\(c.dst_h)")
        }
    }

    func testPreprocessKeepsRawRGBAndExactCorners() throws {
        let image = try Fixtures.image("sink")
        let bytes = try Segmenter.rgbxBytes(image)
        let input = try Segmenter.preprocess(image)
        XCTAssertEqual(input.shape, [1, 3, 1024, 1024])
        let side = 1024 * 1024
        input.withUnsafeBufferPointer(ofType: Float.self) { p in
            for c in 0..<3 {
                // Output (0,0) clamps to source (0,0); (1023,1023) to source (W-1,H-1).
                XCTAssertEqual(p[c * side], Float(bytes[c]))
                XCTAssertEqual(p[c * side + side - 1], Float(bytes[(image.width * image.height - 1) * 4 + c]))
            }
            XCTAssertTrue((0..<(3 * side)).allSatisfy { p[$0] >= 0 && p[$0] <= 255 })
        }
    }
}

final class SegmentationParityTests: XCTestCase {
    // Core ML runs on the CPU in the simulator; the reference masks are Python Core ML CPU_ONLY.
    nonisolated(unsafe) private static var segmenter: Segmenter?

    private func makeSegmenter() throws -> Segmenter {
        if let segmenter = Self.segmenter { return segmenter }
        let segmenter = try Segmenter(computeUnits: .cpuOnly)
        Self.segmenter = segmenter
        return segmenter
    }

    func testSinkParity() async throws { try await checkParity("sink") }
    func testCarParity() async throws { try await checkParity("car") }
    func testGymParity() async throws { try await checkParity("gym") }

    private func checkParity(_ name: String) async throws {
        let segmenter = try makeSegmenter()
        let scene = try Fixtures.scene(name)
        let image = try Fixtures.image(name)
        XCTAssertEqual([image.width, image.height], [scene.width, scene.height])
        let embedding = try await segmenter.embed(image)
        var sam2: [Double] = []
        var lines = ["\(name): pre \(fmt(embedding.preMs)) ms, encoder \(fmt(embedding.encodeMs)) ms"]
        for part in scene.parts {
            let mask = try await segmenter.mask(embedding: embedding, box: PartBox(part.box))
            let python = try Fixtures.mask(name, "coreml_\(part.id)")
            let reference = try Fixtures.mask(name, "sam2_\(part.id)")
            XCTAssertEqual([mask.width, mask.height], [python.width, python.height])
            let iouPython = maskIoU(mask.pixels, python.pixels)
            let iouSAM2 = maskIoU(mask.pixels, reference.pixels)
            sam2.append(iouSAM2)
            lines.append("  \(part.id) selected \(mask.selected) (py \(part.selected)) scores \(mask.scores.map { fmt(Double($0), 4) }) "
                         + "(py \(part.scores.map { fmt(Double($0), 4) })) IoU python \(fmt(iouPython, 4)) "
                         + "IoU SAM2 \(fmt(iouSAM2, 4)) decoder \(fmt(mask.decodeMs)) ms post \(fmt(mask.postMs)) ms")
            XCTAssertGreaterThanOrEqual(iouPython, 0.95, "\(name)/\(part.id) vs Python Core ML")
        }
        let mean = sam2.reduce(0, +) / Double(sam2.count)
        lines.append("  mean IoU SAM2 \(fmt(mean, 4))")
        print("SAM-PARITY " + lines.joined(separator: "\nSAM-PARITY "))
        XCTAssertGreaterThanOrEqual(mean, 0.8, "\(name) scene mean vs SAM2")
    }

    private func fmt(_ value: Double, _ digits: Int = 1) -> String { String(format: "%.\(digits)f", value) }
}
