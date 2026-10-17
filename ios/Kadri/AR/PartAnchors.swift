import ARKit
import KadriCore
import UIKit

struct PartPlacement {
    let id: String
    let anchorID: UUID
    let worldPosition: SIMD3<Float>
    let box: [Int]
    /// Fraction of valid surface samples; a heuristic, not a calibrated probability.
    let confidence: Float
    let worldCorners: [SIMD3<Float>]
    let referenceCenter: CGPoint
}

struct PartProjection: Identifiable {
    let id: String
    let center: CGPoint
    let corners: [CGPoint]
    let returnErrorPixels: CGFloat?
}

@MainActor
final class PartAnchors: ObservableObject {
    @Published private(set) var placements: [PartPlacement] = []
    @Published private(set) var unanchored: [String] = []
    private(set) var anchorIDs: [String: UUID] = [:]
    private var reference: Keyframe?
    private var boxes: [String: [Int]] = [:]

    /// Optional mask samples use JPEG pixel coordinates. IDs are assigned once by
    /// the caller (pN); preserve them when refining boxes or adding mask pixels.
    func place(keyframe: Keyframe, parts: [(id: String, box: [Int])],
               maskPixels: [String: [CGPoint]] = [:], session: ARSession) {
        clear(session: session)
        reference = keyframe
        boxes = Dictionary(parts.map { ($0.id, $0.box) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        for part in parts {
            guard seen.insert(part.id).inserted else { continue }
            let box = part.box
            guard box.count == 4, box.allSatisfy({ (0...1000).contains($0) }), box[0] < box[2], box[1] < box[3] else {
                unanchored.append(part.id); continue
            }
            func pixel(_ x: Float, _ y: Float) -> CGPoint {
                CGPoint(x: CGFloat(x) / 1000 * keyframe.size.width, y: CGFloat(y) / 1000 * keyframe.size.height)
            }
            let center = pixel(Float(box[0]+box[2])/2, Float(box[1]+box[3])/2)
            var samples: [CGPoint] = []
            for y in [Float(0.25), 0.5, 0.75] { for x in [Float(0.25), 0.5, 0.75] {
                samples.append(pixel(Float(box[0]) + Float(box[2]-box[0])*x, Float(box[1]) + Float(box[3]-box[1])*y))
            }}
            if let mask = maskPixels[part.id], !mask.isEmpty {
                // Bound per-part work for dense segmentation masks.
                samples = Array(mask.filter { $0.x >= 0 && $0.y >= 0 && $0.x < keyframe.size.width && $0.y < keyframe.size.height }.prefix(81))
            }
            let depths = samples.compactMap { sample -> Float? in
                if let depth = lidarDepth(at: sample, keyframe: keyframe) { return depth }
                let sensor = keyframe.sensorPoint(sample)
                let resolution = keyframe.snapshot.frame.camera.imageResolution
                let normalized = CGPoint(x: sensor.x/resolution.width, y: sensor.y/resolution.height)
                let query = keyframe.snapshot.frame.raycastQuery(from: normalized, allowing: .estimatedPlane, alignment: .any)
                guard let hit = session.raycast(query).first else { return nil }
                let local = keyframe.cameraTransform.inverse * hit.worldTransform.columns.3
                return -local.z > 0 ? -local.z : nil
            }
            guard let depth = FrameGeometry.medianDepth(depths) else { unanchored.append(part.id); continue }
            func world(_ point: CGPoint) -> SIMD3<Float> {
                FrameGeometry.unproject(SIMD2(Float(point.x), Float(point.y)), depth: depth, intrinsics: keyframe.intrinsics, camera: keyframe.cameraTransform)
            }
            let position = world(center)
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(position, 1)
            let anchor = ARAnchor(name: part.id, transform: transform)
            session.add(anchor: anchor)
            anchorIDs[part.id] = anchor.identifier
            let corners = [pixel(Float(box[0]), Float(box[1])), pixel(Float(box[2]), Float(box[1])), pixel(Float(box[2]), Float(box[3])), pixel(Float(box[0]), Float(box[3]))]
            placements.append(PartPlacement(id: part.id, anchorID: anchor.identifier, worldPosition: position, box: box,
                                            confidence: Float(depths.count)/Float(max(1, samples.count)), worldCorners: corners.map(world), referenceCenter: center))
        }
    }

    func clear(session: ARSession) {
        let identifiers = Set(anchorIDs.values)
        session.currentFrame?.anchors.filter { identifiers.contains($0.identifier) }.forEach { session.remove(anchor: $0) }
        placements = []; unanchored = []; anchorIDs = [:]; reference = nil; boxes = [:]
    }

    func projections(frame: ARFrame, viewport: CGSize, scale: CGFloat) -> [PartProjection] {
        guard let reference else { return [] }
        let delta = reference.snapshot.frame.camera.transform.inverse * frame.camera.transform
        let translation = simd_length(SIMD3(delta.columns.3.x, delta.columns.3.y, delta.columns.3.z))
        let angle = acos(min(1, max(-1, (delta.columns.0.x + delta.columns.1.y + delta.columns.2.z - 1)/2)))
        let similarView = translation < 0.015 && angle < 0.02
        let display = reference.snapshot.frame.displayTransform(for: .portrait, viewportSize: viewport)
        return placements.compactMap { placement in
            guard let anchor = frame.anchors.first(where: { $0.identifier == placement.anchorID }) else { return nil }
            var originalTransform = matrix_identity_float4x4
            originalTransform.columns.3 = SIMD4(placement.worldPosition, 1)
            let update = anchor.transform * originalTransform.inverse
            let position = SIMD3(anchor.transform.columns.3.x, anchor.transform.columns.3.y, anchor.transform.columns.3.z)
            let local = frame.camera.transform.inverse * SIMD4(position, 1)
            guard local.z < 0 else { return nil }
            let center = frame.camera.projectPoint(position, orientation: .portrait, viewportSize: viewport)
            let corners = placement.worldCorners.map { corner in
                let world = update * SIMD4(corner, 1)
                return frame.camera.projectPoint(SIMD3(world.x, world.y, world.z), orientation: .portrait, viewportSize: viewport)
            }
            let sensor = reference.sensorPoint(placement.referenceCenter)
            let resolution = reference.snapshot.frame.camera.imageResolution
            let normalized = CGPoint(x: sensor.x/resolution.width, y: sensor.y/resolution.height).applying(display)
            let original = CGPoint(x: normalized.x*viewport.width, y: normalized.y*viewport.height)
            let error = hypot(center.x-original.x, center.y-original.y)*scale
            return PartProjection(id: placement.id, center: center, corners: corners, returnErrorPixels: similarView ? error : nil)
        }
    }

    /// Failed placements remain fixed in the keyframe's 2D display coordinates.
    /// They are explicitly not world-tracked.
    func unanchoredCenters(viewport: CGSize) -> [(id: String, point: CGPoint)] {
        guard let reference else { return [] }
        let display = reference.snapshot.frame.displayTransform(for: .portrait, viewportSize: viewport)
        let resolution = reference.snapshot.frame.camera.imageResolution
        return unanchored.compactMap { id in
            guard let box = boxes[id], box.count == 4 else { return nil }
            let center = CGPoint(x: CGFloat(box[0]+box[2])/2000*reference.size.width,
                                 y: CGFloat(box[1]+box[3])/2000*reference.size.height)
            let sensor = reference.sensorPoint(center)
            let point = CGPoint(x: sensor.x/resolution.width, y: sensor.y/resolution.height).applying(display)
            return (id, CGPoint(x: point.x*viewport.width, y: point.y*viewport.height))
        }
    }

    private func lidarDepth(at pixel: CGPoint, keyframe: Keyframe) -> Float? {
        guard let depth = keyframe.snapshot.frame.sceneDepth, let confidence = depth.confidenceMap else { return nil }
        let sensor = keyframe.sensorPoint(pixel)
        let size = keyframe.snapshot.frame.camera.imageResolution
        let map = depth.depthMap
        let x = Int(sensor.x/size.width*CGFloat(CVPixelBufferGetWidth(map)))
        let y = Int(sensor.y/size.height*CGFloat(CVPixelBufferGetHeight(map)))
        guard x >= 0, y >= 0, x < CVPixelBufferGetWidth(map), y < CVPixelBufferGetHeight(map),
              CVPixelBufferGetWidth(confidence) == CVPixelBufferGetWidth(map), CVPixelBufferGetHeight(confidence) == CVPixelBufferGetHeight(map) else { return nil }
        CVPixelBufferLockBaseAddress(map, .readOnly)
        CVPixelBufferLockBaseAddress(confidence, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly); CVPixelBufferUnlockBaseAddress(confidence, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map), let quality = CVPixelBufferGetBaseAddress(confidence) else { return nil }
        let level = quality.assumingMemoryBound(to: UInt8.self)[y*CVPixelBufferGetBytesPerRow(confidence)+x]
        guard level >= ARConfidenceLevel.medium.rawValue else { return nil }
        let value = base.advanced(by: y*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)[x]
        return value.isFinite && value > 0 ? value : nil
    }
}
