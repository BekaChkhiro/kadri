import Accelerate
import CoreGraphics
import CoreML
import Foundation
import ImageIO

/// Encoder output for one frame. Share it across every part's decoder call; never mutated.
struct Embedding: @unchecked Sendable {
    let features: MLMultiArray
    let width: Int
    let height: Int
    let preMs: Double
    let encodeMs: Double
}

/// Binary part mask at the original frame size. `pixels` is row-major, 0 or 255.
struct Mask: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let score: Float
    let scores: [Float]
    let selected: Int
    let decodeMs: Double
    let postMs: Double

    var area: Int { pixels.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } }
}

/// EfficientSAM-Ti on Core ML: one encoder pass per frame, one decoder pass per part box.
/// Contract: docs/SAM_COREML.md, "Swift-ის ზუსტი I/O კონტრაქტი".
actor Segmenter {
    nonisolated let computeUnits: MLComputeUnits
    nonisolated let loadMs: Double
    private let encoder: MLModel
    private let decoder: MLModel

    init(computeUnits: MLComputeUnits = .all, bundle: Bundle = .main) throws {
        let start = Clock.now
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        encoder = try MLModel(contentsOf: try Self.modelURL("SAMEncoder", bundle: bundle), configuration: configuration)
        decoder = try MLModel(contentsOf: try Self.modelURL("SAMDecoder", bundle: bundle), configuration: configuration)
        self.computeUnits = computeUnits
        loadMs = Clock.ms(since: start)
    }

    private static func modelURL(_ name: String, bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: "mlmodelc") else {
            throw SegmentationError.modelMissing(name)
        }
        return url
    }

    func embed(_ image: CGImage) async throws -> Embedding {
        let start = Clock.now
        let input = try Self.preprocess(image)
        let preMs = Clock.ms(since: start)
        let encodeStart = Clock.now
        let output = try Self.predict(encoder, MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let features = output.featureValue(for: "embedding")?.multiArrayValue,
              features.shape.map(\.intValue) == [1, 256, 64, 64] else {
            throw SegmentationError.unexpectedOutput("embedding")
        }
        return Embedding(features: features, width: image.width, height: image.height,
                         preMs: preMs, encodeMs: Clock.ms(since: encodeStart))
    }

    /// `imageSize` defaults to the embedded frame; the box must belong to that same oriented frame.
    func mask(embedding: Embedding, box: PartBox, imageSize: CGSize? = nil) async throws -> Mask {
        let width = imageSize.map { Int($0.width) } ?? embedding.width
        let height = imageSize.map { Int($0.height) } ?? embedding.height
        let prompt = try SAMGeometry.promptBox(box, width: width, height: height)
        let boxArray = try MLMultiArray(shape: [4], dataType: .float32)
        boxArray.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            for i in 0..<4 { ptr[i] = prompt[i] }
        }
        let decodeStart = Clock.now
        let output = try Self.predict(decoder, MLDictionaryFeatureProvider(dictionary: [
            "embedding": embedding.features, "box": boxArray,
        ]))
        let decodeMs = Clock.ms(since: decodeStart)
        guard let logits = output.featureValue(for: "mask_logits")?.multiArrayValue,
              logits.shape.map(\.intValue) == [1, 3, 256, 256], logits.dataType == .float32 else {
            throw SegmentationError.unexpectedOutput("mask_logits")
        }
        guard let scoresArray = output.featureValue(for: "iou_scores")?.multiArrayValue,
              scoresArray.count == 3 else {
            throw SegmentationError.unexpectedOutput("iou_scores")
        }
        let postStart = Clock.now
        let scores = (0..<3).map { scoresArray[[0, $0] as [NSNumber]].floatValue }
        // argmax; the first index wins ties, like numpy.
        var selected = 0
        for i in 1..<3 where scores[i] > scores[selected] { selected = i }
        let pixels = Self.postprocess(logits, plane: selected, width: width, height: height)
        return Mask(width: width, height: height, pixels: pixels, score: scores[selected], scores: scores,
                    selected: selected, decodeMs: decodeMs, postMs: Clock.ms(since: postStart))
    }

    /// Synchronous prediction on the actor (the async overload would send the model across isolation).
    private static func predict(_ model: MLModel, _ input: MLFeatureProvider) throws -> MLFeatureProvider {
        try model.prediction(from: input)
    }

    /// RGB 0…255 Float32 NCHW, direct bilinear resize to 1024×1024 (no aspect, no padding,
    /// no normalization — that is inside the model).
    static func preprocess(_ image: CGImage) throws -> MLMultiArray {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw SegmentationError.invalidImageSize(width: width, height: height) }
        let rgbx = try rgbxBytes(image)
        let side = SAMGeometry.side
        let input = try MLMultiArray(shape: [1, 3, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        var plane = [Float](repeating: 0, count: width * height)
        input.withUnsafeMutableBufferPointer(ofType: Float.self) { dst, strides in
            precondition(strides.map(\.self) == [3 * side * side, side * side, side, 1], "non-contiguous input")
            rgbx.withUnsafeBufferPointer { bytes in
                plane.withUnsafeMutableBufferPointer { plane in
                    for c in 0..<3 {
                        vDSP_vfltu8(bytes.baseAddress! + c, 4, plane.baseAddress!, 1, vDSP_Length(width * height))
                        SAMResample.bilinear(plane.baseAddress!, width: width, height: height,
                                             into: dst.baseAddress! + c * side * side, width: side, height: side)
                    }
                }
            }
        }
        return input
    }

    /// Raw 8-bit RGBX pixels in the image's own RGB colour space (no colour conversion, like PIL).
    static func rgbxBytes(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw SegmentationError.imageDecodeFailed }
        return bytes
    }

    /// Selected 256×256 logits → bicubic straight to H×W → threshold > 0 (after the resize).
    static func postprocess(_ logits: MLMultiArray, plane: Int, width: Int, height: Int) -> [UInt8] {
        let n = SAMGeometry.lowRes
        var low = [Float](repeating: 0, count: n * n)
        logits.withUnsafeBufferPointer(ofType: Float.self) { src in
            let s = logits.strides.map(\.intValue)
            for y in 0..<n {
                for x in 0..<n { low[y * n + x] = src[plane * s[1] + y * s[2] + x * s[3]] }
            }
        }
        var full = [Float](repeating: 0, count: width * height)
        low.withUnsafeBufferPointer { low in
            full.withUnsafeMutableBufferPointer { full in
                SAMResample.bicubic(low.baseAddress!, width: n, height: n,
                                    into: full.baseAddress!, width: width, height: height)
            }
        }
        return full.map { $0 > 0 ? 255 : 0 }
    }
}

enum SegmentationImage {
    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SegmentationError.imageDecodeFailed
        }
        return image
    }

    /// Masks tinted in distinct colours on a transparent RGBA canvas, for overlays.
    static func overlay(_ masks: [Mask]) -> CGImage? {
        guard let first = masks.first else { return nil }
        let width = first.width, height = first.height
        let palette: [(UInt8, UInt8, UInt8)] = [(255, 92, 0), (0, 200, 255), (255, 214, 0), (170, 90, 255),
                                                  (60, 220, 120), (255, 60, 140), (255, 255, 255)]
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for (k, mask) in masks.enumerated() where mask.width == width && mask.height == height {
            let (r, g, b) = palette[k % palette.count]
            for i in 0..<(width * height) where mask.pixels[i] > 0 {
                // Premultiplied at alpha 150/255.
                rgba[i * 4] = UInt8(Int(r) * 150 / 255)
                rgba[i * 4 + 1] = UInt8(Int(g) * 150 / 255)
                rgba[i * 4 + 2] = UInt8(Int(b) * 150 / 255)
                rgba[i * 4 + 3] = 150
            }
        }
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum Clock {
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }
    static func ms(since start: UInt64) -> Double { Double(now - start) / 1e6 }
}
