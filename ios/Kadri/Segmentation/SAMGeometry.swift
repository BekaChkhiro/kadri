import Accelerate
import Foundation
import KadriCore

/// A part box on the AI's 0–1000 XYXY grid, in the oriented frame's coordinates.
struct PartBox: Hashable, Codable, Sendable {
    let x0: Int
    let y0: Int
    let x1: Int
    let y1: Int

    init(x0: Int, y0: Int, x1: Int, y1: Int) {
        self.x0 = x0
        self.y0 = y0
        self.x1 = x1
        self.y1 = y1
    }

    init(_ values: [Int]) throws {
        guard values.count == 4 else { throw SegmentationError.invalidBox(values) }
        self.init(x0: values[0], y0: values[1], x1: values[2], y1: values[3])
    }

    init(_ part: Part) throws {
        try self.init(part.box)
    }

    var values: [Int] { [x0, y0, x1, y1] }

    var isValid: Bool {
        values.allSatisfy { (0...1000).contains($0) } && x0 < x1 && y0 < y1
    }
}

enum SegmentationError: Error, Equatable, LocalizedError {
    case modelMissing(String)
    case invalidBox([Int])
    case invalidImageSize(width: Int, height: Int)
    case imageDecodeFailed
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing(let name): "მოდელი ვერ მოიძებნა: \(name)"
        case .invalidBox(let box): "box არასწორია: \(box)"
        case .invalidImageSize(let w, let h): "კადრის ზომა არასწორია: \(w)×\(h)"
        case .imageDecodeFailed: "სურათის წაკითხვა ვერ მოხერხდა"
        case .unexpectedOutput(let name): "მოდელმა მოულოდნელი შედეგი დააბრუნა: \(name)"
        }
    }
}

/// EfficientSAM-Ti geometry, exactly as `docs/SAM_COREML.md` (Swift I/O contract) and
/// `ios/Tools/sam_common.py` with `square=True`.
enum SAMGeometry {
    static let side = 1024
    static let lowRes = 256

    /// 0–1000 XYXY → original pixels (floor/ceil outwards) → 1024×1024 prompt coordinates.
    static func promptBox(_ box: PartBox, width: Int, height: Int) throws -> [Float] {
        guard box.isValid else { throw SegmentationError.invalidBox(box.values) }
        guard width > 0, height > 0 else { throw SegmentationError.invalidImageSize(width: width, height: height) }
        let pixels = boxPixels(box, width: width, height: height)
        let sx = Float(Double(side) / Double(width))
        let sy = Float(Double(side) / Double(height))
        return [pixels[0] * sx, pixels[1] * sy, pixels[2] * sx, pixels[3] * sy]
    }

    static func boxPixels(_ box: PartBox, width: Int, height: Int) -> [Float] {
        let w = Double(width), h = Double(height)
        return [
            Float((Double(box.x0) * w / 1000).rounded(.down)),
            Float((Double(box.y0) * h / 1000).rounded(.down)),
            Float((Double(box.x1) * w / 1000).rounded(.up)),
            Float((Double(box.y1) * h / 1000).rounded(.up)),
        ]
    }
}

/// PyTorch-compatible `F.interpolate(..., align_corners=False)` on single-channel Float32 planes.
enum SAMResample {
    /// Source coordinate of an output pixel centre: `(dst + 0.5) * src/dst - 0.5` (unclamped).
    static func sourceCoordinate(_ dst: Int, sourceSize: Int, destinationSize: Int) -> Float {
        let scale = Float(sourceSize) / Float(destinationSize)
        return scale * (Float(dst) + 0.5) - 0.5
    }

    struct Taps2 {
        var i0: [Int] = []
        var i1: [Int] = []
        var w0: [Float] = []
        var w1: [Float] = []
    }

    /// Linear taps; source clamps at 0 and the second index at `n - 1` (PyTorch upsample_bilinear2d).
    static func linearTaps(source: Int, destination: Int) -> Taps2 {
        var taps = Taps2()
        for d in 0..<destination {
            let real = max(sourceCoordinate(d, sourceSize: source, destinationSize: destination), 0)
            let i = Int(real)
            let lambda = real - Float(i)
            taps.i0.append(i)
            taps.i1.append(min(i + 1, source - 1))
            taps.w0.append(1 - lambda)
            taps.w1.append(lambda)
        }
        return taps
    }

    struct Taps4 {
        var index: [Int] = []   // 4 per output, clamped to 0..<n
        var weight: [Float] = []
    }

    /// Keys cubic (a = -0.75), taps clamped to the border (PyTorch upsample_bicubic2d).
    static func cubicTaps(source: Int, destination: Int) -> Taps4 {
        let a: Float = -0.75
        func near(_ x: Float) -> Float { ((a + 2) * x - (a + 3)) * x * x + 1 }
        func far(_ x: Float) -> Float { ((a * x - 5 * a) * x + 8 * a) * x - 4 * a }
        var taps = Taps4()
        taps.index.reserveCapacity(destination * 4)
        taps.weight.reserveCapacity(destination * 4)
        for d in 0..<destination {
            let real = sourceCoordinate(d, sourceSize: source, destinationSize: destination)
            let i = Int(real.rounded(.down))
            let t = real - Float(i)
            taps.weight += [far(t + 1), near(t), near(1 - t), far(2 - t)]
            for j in 0..<4 { taps.index.append(min(max(i - 1 + j, 0), source - 1)) }
        }
        return taps
    }

    /// Bilinear resize, horizontal pass then vertical pass (matching PyTorch's order).
    static func bilinear(_ src: UnsafePointer<Float>, width: Int, height: Int,
                         into dst: UnsafeMutablePointer<Float>, width dw: Int, height dh: Int) {
        let tx = linearTaps(source: width, destination: dw)
        let ty = linearTaps(source: height, destination: dh)
        var rows = [Float](repeating: 0, count: height * dw)
        rows.withUnsafeMutableBufferPointer { rows in
            tx.i0.withUnsafeBufferPointer { i0 in
            tx.i1.withUnsafeBufferPointer { i1 in
            tx.w0.withUnsafeBufferPointer { w0 in
            tx.w1.withUnsafeBufferPointer { w1 in
                for y in 0..<height {
                    let s = src + y * width
                    let r = rows.baseAddress! + y * dw
                    for x in 0..<dw {
                        r[x] = w0[x] * s[i0[x]] + w1[x] * s[i1[x]]
                    }
                }
            }}}}
            for y in 0..<dh {
                vDSP_vsmsma(rows.baseAddress! + ty.i0[y] * dw, 1, [ty.w0[y]],
                            rows.baseAddress! + ty.i1[y] * dw, 1, [ty.w1[y]],
                            dst + y * dw, 1, vDSP_Length(dw))
            }
        }
    }

    /// Bicubic resize, horizontal pass then vertical pass.
    static func bicubic(_ src: UnsafePointer<Float>, width: Int, height: Int,
                        into dst: UnsafeMutablePointer<Float>, width dw: Int, height dh: Int) {
        let tx = cubicTaps(source: width, destination: dw)
        let ty = cubicTaps(source: height, destination: dh)
        var rows = [Float](repeating: 0, count: height * dw)
        rows.withUnsafeMutableBufferPointer { rows in
            tx.index.withUnsafeBufferPointer { ix in
            tx.weight.withUnsafeBufferPointer { wx in
                for y in 0..<height {
                    let s = src + y * width
                    let r = rows.baseAddress! + y * dw
                    for x in 0..<dw {
                        let k = x * 4
                        r[x] = wx[k] * s[ix[k]] + wx[k + 1] * s[ix[k + 1]]
                            + wx[k + 2] * s[ix[k + 2]] + wx[k + 3] * s[ix[k + 3]]
                    }
                }
            }}
            let base = rows.baseAddress!
            let n = vDSP_Length(dw)
            for y in 0..<dh {
                let k = y * 4
                let out = dst + y * dw
                vDSP_vsmsma(base + ty.index[k] * dw, 1, [ty.weight[k]],
                            base + ty.index[k + 1] * dw, 1, [ty.weight[k + 1]], out, 1, n)
                vDSP_vsma(base + ty.index[k + 2] * dw, 1, [ty.weight[k + 2]], out, 1, out, 1, n)
                vDSP_vsma(base + ty.index[k + 3] * dw, 1, [ty.weight[k + 3]], out, 1, out, 1, n)
            }
        }
    }
}
