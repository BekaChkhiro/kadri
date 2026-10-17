import Foundation
import simd

public enum FrameGeometry {
    public static func resized(width: Int, height: Int, longest: Int = 768) -> SIMD2<Int> {
        guard width > 0, height > 0, longest > 0 else { return .zero }
        let scale = Double(longest) / Double(max(width, height))
        return SIMD2(Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }

    public static func scaledIntrinsics(_ k: simd_float3x3, scale: SIMD2<Float>) -> simd_float3x3 {
        var result = k
        for column in 0..<3 {
            result[column][0] *= scale.x
            result[column][1] *= scale.y
        }
        return result
    }

    /// Image coordinates are top-left; AR camera looks along -Z with +Y up.
    public static func unproject(_ pixel: SIMD2<Float>, depth: Float, intrinsics: simd_float3x3,
                                 camera: simd_float4x4) -> SIMD3<Float> {
        let ray = intrinsics.inverse * SIMD3(pixel.x, pixel.y, 1)
        let world = camera * SIMD4(ray.x * depth, -ray.y * depth, -depth, 1)
        return SIMD3(world.x, world.y, world.z)
    }

    public static func project(_ world: SIMD3<Float>, intrinsics: simd_float3x3,
                               camera: simd_float4x4) -> SIMD2<Float>? {
        let local = camera.inverse * SIMD4(world, 1)
        guard local.z < -0.0001 else { return nil }
        let p = intrinsics * SIMD3(local.x / -local.z, -local.y / -local.z, 1)
        return SIMD2(p.x, p.y)
    }

    public static func pixel(_ normalized: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        normalized * size / 1000
    }

    public static func normalized(_ pixel: SIMD2<Float>, size: SIMD2<Float>) -> SIMD2<Float> {
        pixel / size * 1000
    }

    public static func medianDepth(_ values: [Float]) -> Float? {
        let sorted = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    /// 8-bit grayscale, four-neighbour Laplacian; excludes the one-pixel border.
    public static func laplacianVariance(_ pixels: [UInt8], width: Int, height: Int) -> Double {
        guard width > 2, height > 2, pixels.count == width * height else { return 0 }
        var sum = 0.0, squares = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let i = y * width + x
                let v = Double(Int(pixels[i-1]) + Int(pixels[i+1]) + Int(pixels[i-width]) + Int(pixels[i+width]) - 4 * Int(pixels[i]))
                sum += v; squares += v * v
            }
        }
        let count = Double((width - 2) * (height - 2))
        return max(0, squares / count - pow(sum / count, 2))
    }
}
