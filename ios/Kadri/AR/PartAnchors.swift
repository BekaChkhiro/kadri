import ARKit
import KadriCore
import UIKit

/// Detached camera geometry. Never retains an ARFrame or a camera pixel buffer.
struct PartReference: Sendable {
    let size: CGSize
    let cameraTransform: simd_float4x4
    let sensorTransform: simd_float4x4
    let intrinsics: simd_float3x3
    let sensorSize: CGSize
    let depthSize: SIMD2<Int>
    let depths: [Float]

    init(keyframe: Keyframe) {
        size = keyframe.size; cameraTransform = keyframe.cameraTransform
        intrinsics = keyframe.intrinsics
        sensorTransform = keyframe.snapshot.frame.camera.transform
        sensorSize = keyframe.snapshot.frame.camera.imageResolution
        if let depth = keyframe.snapshot.frame.sceneDepth, let confidence = depth.confidenceMap {
            let map = depth.depthMap
            let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
            depthSize = SIMD2(w, h)
            var values = [Float](repeating: 0, count: w*h)
            CVPixelBufferLockBaseAddress(map, .readOnly)
            CVPixelBufferLockBaseAddress(confidence, .readOnly)
            if CVPixelBufferGetWidth(confidence) == w, CVPixelBufferGetHeight(confidence) == h,
               let base = CVPixelBufferGetBaseAddress(map), let quality = CVPixelBufferGetBaseAddress(confidence) {
                for y in 0..<h {
                    let row = base.advanced(by: y*CVPixelBufferGetBytesPerRow(map)).assumingMemoryBound(to: Float.self)
                    let q = quality.advanced(by: y*CVPixelBufferGetBytesPerRow(confidence)).assumingMemoryBound(to: UInt8.self)
                    for x in 0..<w where q[x] >= ARConfidenceLevel.medium.rawValue { values[y*w+x] = row[x] }
                }
            }
            CVPixelBufferUnlockBaseAddress(confidence, .readOnly)
            CVPixelBufferUnlockBaseAddress(map, .readOnly)
            depths = values
        } else { depthSize = .zero; depths = [] }
    }

    // Also useful for geometry-only fixtures; no fabricated ARFrame is needed.
    init(size: CGSize, cameraTransform: simd_float4x4, intrinsics: simd_float3x3, depth: Float? = nil) {
        self.size = size; self.cameraTransform = cameraTransform; self.intrinsics = intrinsics
        sensorTransform = cameraTransform; sensorSize = CGSize(width: size.height, height: size.width)
        depthSize = depth == nil ? .zero : SIMD2(2, 2)
        depths = depth.map { Array(repeating: $0, count: 4) } ?? []
    }

    func displayPoint(_ pixel: CGPoint, viewport: CGSize) -> CGPoint {
        let scale = max(viewport.width/size.width, viewport.height/size.height)
        return CGPoint(x: pixel.x*scale + (viewport.width-size.width*scale)/2,
                       y: pixel.y*scale + (viewport.height-size.height*scale)/2)
    }

    func depth(at pixel: CGPoint) -> Float? {
        guard depthSize.x > 0, depthSize.y > 0 else { return nil }
        let x = Int(pixel.y/size.height*CGFloat(depthSize.x))
        let y = Int((1-pixel.x/size.width)*CGFloat(depthSize.y))
        guard x >= 0, y >= 0, x < depthSize.x, y < depthSize.y else { return nil }
        let value = depths[y*depthSize.x+x]
        return value.isFinite && value > 0 ? value : nil
    }
}

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
    private var references: [String: PartReference] = [:]
    private var sessionAnchors: [String: ARAnchor] = [:]
    private var boxes: [String: [Int]] = [:]

    /// Optional mask samples use JPEG pixel coordinates. IDs are assigned once by
    /// the caller (pN); preserve them when refining boxes or adding mask pixels.
    func place(keyframe: Keyframe, parts: [(id: String, box: [Int])],
               maskPixels: [String: [CGPoint]] = [:], session: ARSession) {
        clear(session: session)
        append(reference: PartReference(keyframe: keyframe), parts: parts, maskPixels: maskPixels, session: session)
    }

    func append(reference keyframe: PartReference, parts: [(id: String, box: [Int])],
                maskPixels: [String: [CGPoint]] = [:], session: ARSession) {
        var seen = Set<String>()
        for part in parts {
            guard seen.insert(part.id).inserted, references[part.id] == nil else { continue }
            references[part.id] = keyframe
            boxes[part.id] = part.box
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
                if let depth = keyframe.depth(at: sample) { return depth }
                let origin = keyframe.cameraTransform.columns.3
                let target = FrameGeometry.unproject(SIMD2(Float(sample.x), Float(sample.y)), depth: 1,
                                                     intrinsics: keyframe.intrinsics, camera: keyframe.cameraTransform)
                let camera = SIMD3(origin.x, origin.y, origin.z)
                let query = ARRaycastQuery(origin: camera, direction: simd_normalize(target-camera),
                                          allowing: .estimatedPlane, alignment: .any)
                guard let hit = session.raycast(query).first else { return nil }
                let local = keyframe.cameraTransform.inverse * hit.worldTransform.columns.3
                return -local.z > 0 ? -local.z : nil
            }
            // Without LiDAR, estimated-plane raycasts miss until ARKit has found a plane (often the first
            // seconds after tracking turns normal). Fall back to sparse feature points inside the box, then
            // to the median depth of all visible feature points.
            func featureDepths(inside rect: [Int]?) -> [Float] {
                guard let points = session.currentFrame?.rawFeaturePoints?.points else { return [] }
                return points.compactMap { point in
                    guard let p = FrameGeometry.project(point, intrinsics: keyframe.intrinsics, camera: keyframe.cameraTransform),
                          p.x >= 0, p.y >= 0, Double(p.x) < keyframe.size.width, Double(p.y) < keyframe.size.height else { return nil }
                    if let rect {
                        let n = FrameGeometry.normalized(p, size: SIMD2(Float(keyframe.size.width), Float(keyframe.size.height)))
                        guard n.x >= Float(rect[0]), n.x <= Float(rect[2]), n.y >= Float(rect[1]), n.y <= Float(rect[3]) else { return nil }
                    }
                    let local = keyframe.cameraTransform.inverse * SIMD4(point, 1)
                    return -local.z
                }
            }
            var fallback = depths.isEmpty ? featureDepths(inside: box) : []
            if depths.isEmpty, fallback.count < 3 { fallback = featureDepths(inside: nil) }
            guard let depth = FrameGeometry.medianDepth(depths.isEmpty ? fallback : depths) else { unanchored.append(part.id); continue }
            func world(_ point: CGPoint) -> SIMD3<Float> {
                FrameGeometry.unproject(SIMD2(Float(point.x), Float(point.y)), depth: depth, intrinsics: keyframe.intrinsics, camera: keyframe.cameraTransform)
            }
            let position = world(center)
            var transform = matrix_identity_float4x4
            transform.columns.3 = SIMD4(position, 1)
            let anchor = ARAnchor(name: part.id, transform: transform)
            session.add(anchor: anchor)
            sessionAnchors[part.id] = anchor
            anchorIDs[part.id] = anchor.identifier
            let corners = [pixel(Float(box[0]), Float(box[1])), pixel(Float(box[2]), Float(box[1])), pixel(Float(box[2]), Float(box[3])), pixel(Float(box[0]), Float(box[3]))]
            placements.append(PartPlacement(id: part.id, anchorID: anchor.identifier, worldPosition: position, box: box,
                                            confidence: Float(depths.count)/Float(max(1, samples.count)), worldCorners: corners.map(world), referenceCenter: center))
        }
    }

    func remove(id: String, session: ARSession) {
        if let anchor = sessionAnchors.removeValue(forKey: id) { session.remove(anchor: anchor) }
        placements.removeAll { $0.id == id }; unanchored.removeAll { $0 == id }
        anchorIDs.removeValue(forKey: id); references.removeValue(forKey: id); boxes.removeValue(forKey: id)
    }

    func clear(session: ARSession) {
        sessionAnchors.values.forEach { session.remove(anchor: $0) }
        placements = []; unanchored = []; anchorIDs = [:]; references = [:]; boxes = [:]; sessionAnchors = [:]
    }

    func projections(frame: ARFrame, viewport: CGSize, scale: CGFloat) -> [PartProjection] {
        return placements.compactMap { placement in
            guard let reference = references[placement.id] else { return nil }
            let delta = reference.sensorTransform.inverse * frame.camera.transform
            let translation = simd_length(SIMD3(delta.columns.3.x, delta.columns.3.y, delta.columns.3.z))
            let angle = acos(min(1, max(-1, (delta.columns.0.x + delta.columns.1.y + delta.columns.2.z - 1)/2)))
            let similarView = translation < 0.015 && angle < 0.02
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
            let original = reference.displayPoint(placement.referenceCenter, viewport: viewport)
            let error = hypot(center.x-original.x, center.y-original.y)*scale
            return PartProjection(id: placement.id, center: center, corners: corners, returnErrorPixels: similarView ? error : nil)
        }
    }

    func unanchoredBoxes(viewport: CGSize) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for id in unanchored {
            guard let reference = references[id], let box = boxes[id], box.count == 4 else { continue }
            let a = reference.displayPoint(CGPoint(x: CGFloat(box[0])/1000*reference.size.width,
                                                   y: CGFloat(box[1])/1000*reference.size.height), viewport: viewport)
            let b = reference.displayPoint(CGPoint(x: CGFloat(box[2])/1000*reference.size.width,
                                                   y: CGFloat(box[3])/1000*reference.size.height), viewport: viewport)
            result[id] = CGRect(x: a.x, y: a.y, width: b.x-a.x, height: b.y-a.y)
        }
        return result
    }

    /// Failed placements remain fixed in the keyframe's 2D display coordinates.
    /// They are explicitly not world-tracked.
    func unanchoredCenters(viewport: CGSize) -> [(id: String, point: CGPoint)] {
        return unanchored.compactMap { id in
            guard let reference = references[id], let box = boxes[id], box.count == 4 else { return nil }
            let center = CGPoint(x: CGFloat(box[0]+box[2])/2000*reference.size.width,
                                 y: CGFloat(box[1]+box[3])/2000*reference.size.height)
            return (id, reference.displayPoint(center, viewport: viewport))
        }
    }
}
