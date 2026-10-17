@preconcurrency import ARKit
import CoreImage
import ImageIO
import KadriCore
import UIKit

// ARFrame and its pixel buffers are immutable retained snapshots. Only this wrapper
// crosses the serial image-processing actor; no mutable ARSession crosses it.
struct FrameSnapshot: @unchecked Sendable {
    let frame: ARFrame
    var timestamp: TimeInterval { frame.timestamp }
}

struct Keyframe: @unchecked Sendable {
    let jpegData: Data
    let size: CGSize
    let cameraTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let timestamp: TimeInterval
    let sharpness: Double
    let snapshot: FrameSnapshot
    var depthMap: CVPixelBuffer? { snapshot.frame.sceneDepth?.depthMap }

    // Portrait JPEG is the sensor image rotated clockwise.
    func sensorPoint(_ pixel: CGPoint) -> CGPoint {
        let resolution = snapshot.frame.camera.imageResolution
        return CGPoint(x: pixel.y / size.height * resolution.width,
                       y: (1 - pixel.x / size.width) * resolution.height)
    }
}

actor KeyframePicker {
    struct Configuration: Sendable {
        /// Four-neighbour Laplacian variance on 192px 8-bit grayscale; starting
        /// heuristic 80, to be calibrated on the two acceptance devices.
        var minimumSharpness: Double = 80
        var maximumTranslation: Float = 0.015
        var maximumRotationRadians: Float = 0.035
        var stabilityWindow: TimeInterval = 0.3
    }
    enum Failure: Error { case unstable, blurry(Double), encoding }
    let configuration: Configuration
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(configuration: Configuration = .init()) { self.configuration = configuration }

    func pick(_ frames: [FrameSnapshot]) throws -> Keyframe {
        guard let latest = frames.last else { throw Failure.unstable }
        // Frames are sampled ~0.1 s apart (ARSessionController), so allow one extra sample of slack;
        // with only 0.05 s the oldest sample in range was ~0.23 s old and the 0.3 s check never passed.
        let window = frames.filter { latest.timestamp - $0.timestamp <= configuration.stabilityWindow + 0.15 }
        guard let first = window.first, latest.timestamp - first.timestamp >= configuration.stabilityWindow else { throw Failure.unstable }
        let reference = latest.frame.camera.transform
        for item in window {
            guard case .normal = item.frame.camera.trackingState else { throw Failure.unstable }
            let delta = reference.inverse * item.frame.camera.transform
            let distance = simd_length(SIMD3(delta.columns.3.x, delta.columns.3.y, delta.columns.3.z))
            let angle = acos(min(1, max(-1, (delta.columns.0.x + delta.columns.1.y + delta.columns.2.z - 1) / 2)))
            guard distance <= configuration.maximumTranslation, angle <= configuration.maximumRotationRadians else { throw Failure.unstable }
        }
        let input = CIImage(cvPixelBuffer: latest.frame.capturedImage).oriented(.right)
        let smallSize = FrameGeometry.resized(width: Int(input.extent.width), height: Int(input.extent.height), longest: 192)
        let small = input.transformed(by: CGAffineTransform(scaleX: CGFloat(smallSize.x) / input.extent.width, y: CGFloat(smallSize.y) / input.extent.height))
        var pixels = [UInt8](repeating: 0, count: smallSize.x * smallSize.y)
        pixels.withUnsafeMutableBytes { bytes in
            context.render(small, toBitmap: bytes.baseAddress!, rowBytes: smallSize.x,
                           bounds: CGRect(x: 0, y: 0, width: smallSize.x, height: smallSize.y), format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        }
        let score = FrameGeometry.laplacianVariance(pixels, width: smallSize.x, height: smallSize.y)
        guard score >= configuration.minimumSharpness else { throw Failure.blurry(score) }
        let size = FrameGeometry.resized(width: Int(input.extent.width), height: Int(input.extent.height))
        let output = input.transformed(by: CGAffineTransform(scaleX: CGFloat(size.x) / input.extent.width, y: CGFloat(size.y) / input.extent.height))
        guard let data = context.jpegRepresentation(of: output, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]) else { throw Failure.encoding }
        let camera = latest.frame.camera
        let k = camera.intrinsics
        let rotated = simd_float3x3(columns: (SIMD3(k[1][1], 0, 0), SIMD3(0, k[0][0], 0), SIMD3(Float(input.extent.width) - k[2][1], k[2][0], 1)))
        let rotation = simd_float4x4(columns: (SIMD4(0, 1, 0, 0), SIMD4(-1, 0, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
        return Keyframe(jpegData: data, size: CGSize(width: size.x, height: size.y), cameraTransform: camera.transform * rotation,
                        intrinsics: FrameGeometry.scaledIntrinsics(rotated, scale: SIMD2(Float(size.x) / Float(input.extent.width), Float(size.y) / Float(input.extent.height))),
                        timestamp: latest.timestamp, sharpness: score, snapshot: latest)
    }
}
