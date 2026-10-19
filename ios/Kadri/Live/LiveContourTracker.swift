@preconcurrency import ARKit
import CoreImage
import ImageIO
import Combine
import KadriCore

private struct LiveContourPrompt: Sendable {
    let warp: LiveContourWarp
    let box: CGRect
    let previous: [[CGPoint]]?
}

private struct LiveContourResult: Sendable {
    let id: String
    let mask: Mask
    let polygons: [[CGPoint]]?
    let refresh: Bool
}

/// Uses the existing box decoder. Inference and IoU run off the main actor;
/// each prompt keeps the projection from the very frame being segmented.
private actor LiveContourProcessor {
    private let context = CIContext(options: [.cacheIntermediates: false])

    func process(snapshot: FrameSnapshot, jpeg: Data?, prompts: [String: LiveContourPrompt]) async throws -> [LiveContourResult] {
        try Task.checkCancellation()
        let image: CGImage
        if let jpeg, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) { image = decoded }
        else {
            let input = CIImage(cvPixelBuffer: snapshot.frame.capturedImage).oriented(.right)
            let size = FrameGeometry.resized(width: Int(input.extent.width), height: Int(input.extent.height))
            let scaled = input.transformed(by: CGAffineTransform(scaleX: CGFloat(size.x)/input.extent.width,
                                                                y: CGFloat(size.y)/input.extent.height))
            guard let rendered = context.createCGImage(scaled, from: scaled.extent) else { throw SegmentationError.imageDecodeFailed }
            image = rendered
        }
        let model = try await Segmenter.shared()
        let embedding = try await model.embed(image)
        var result: [LiveContourResult] = []
        for id in prompts.keys.sorted() {
            try Task.checkCancellation()
            let prompt = prompts[id]!, box = prompt.box
            let partBox = PartBox(x0: max(0, Int(floor(box.minX*1000))), y0: max(0, Int(floor(box.minY*1000))),
                                  x1: min(1000, Int(ceil(box.maxX*1000))), y1: min(1000, Int(ceil(box.maxY*1000))))
            guard partBox.isValid else { continue }
            let mask = try await model.mask(embedding: embedding, box: partBox)
            try Task.checkCancellation()
            let candidate = try MaskContours.extract(mask)
            let polygons: [[CGPoint]]?
            if let previous = prompt.previous {
                polygons = LiveContourGeometry.accept(previous: previous, candidate: candidate, captureWarp: prompt.warp)
            } else if let canonical = prompt.warp.polygons(candidate, inverse: true) {
                let sampled = canonical.map { LiveContourGeometry.resample($0) }
                polygons = sampled.allSatisfy { $0.count >= 3 } ? sampled : nil
            } else { polygons = nil }
            result.append(LiveContourResult(id: id, mask: mask, polygons: polygons, refresh: prompt.previous != nil))
        }
        return result
    }
}

@MainActor
final class LiveContourTracker: ObservableObject {
    private struct Entry {
        // Keep the initial binary mask as the reference, alongside its plane-space contour.
        let initialMask: Mask
        var polygons: [[CGPoint]]
    }
    @Published private(set) var contours: [TrackedContour] = []
    @Published private(set) var status = ""
    @Published private(set) var refreshAccepted = 0
    @Published private(set) var refreshRejected = 0
    private var entries: [String: Entry] = [:]
    private let processor = LiveContourProcessor()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var enabled = false
    private var lastFinished: TimeInterval = 0
    // The old debug tracker refreshes every 30 frames. Keep the shape for at
    // least three seconds after inference; AR projection still updates every frame.
    private let refreshInterval: TimeInterval = 3

    func start(keyframe: Keyframe, placements: [PartPlacement]) {
        enabled = true
        var prompts: [String: LiveContourPrompt] = [:]
        for placement in placements where entries[placement.id] == nil {
            let b = placement.box
            guard b.count == 4 else { continue }
            let box = CGRect(x: CGFloat(b[0])/1000, y: CGFloat(b[1])/1000,
                             width: CGFloat(b[2]-b[0])/1000, height: CGFloat(b[3]-b[1])/1000)
            guard let warp = LiveContourWarp(quad: LiveContourWarp.corners(box)) else { continue }
            prompts[placement.id] = LiveContourPrompt(warp: warp, box: box, previous: nil)
        }
        guard !prompts.isEmpty else { return }
        generation += 1; task?.cancel()
        launch(snapshot: keyframe.snapshot, jpeg: keyframe.jpegData, prompts: prompts)
    }

    func stop() {
        enabled = false; generation += 1; task?.cancel(); task = nil
        entries = [:]; contours = []; status = ""; lastFinished = 0
        refreshAccepted = 0; refreshRejected = 0
    }

    func update(snapshot: FrameSnapshot, anchors: PartAnchors) {
        guard enabled, task == nil, snapshot.timestamp-lastFinished >= refreshInterval,
              case .normal = snapshot.frame.camera.trackingState else { return }
        let resolution = snapshot.frame.camera.imageResolution
        let size = CGSize(width: resolution.height, height: resolution.width)
        let projections = anchors.projections(frame: snapshot.frame, viewport: size, scale: 1)
        var prompts: [String: LiveContourPrompt] = [:]
        for projection in projections {
            let quad = projection.corners.map { CGPoint(x: $0.x/size.width, y: $0.y/size.height) }
            guard let warp = LiveContourWarp(quad: quad) else { continue }
            let previous = entries[projection.id]?.polygons
            let predicted = previous.flatMap { warp.polygons($0) }
            let box = ContourGeometry.bounds(predicted?.flatMap { $0 } ?? quad)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard ContourGeometry.valid(box) else { continue }
            prompts[projection.id] = LiveContourPrompt(warp: warp, box: box, previous: previous)
        }
        guard !prompts.isEmpty else { return }
        launch(snapshot: snapshot, jpeg: nil, prompts: prompts)
    }

    /// Only visible, trusted AR projections enter this path. No fixed-screen fallback.
    func projected(_ projections: [PartProjection]) -> [TrackedContour] {
        projections.compactMap { projection in
            guard let entry = entries[projection.id], let warp = LiveContourWarp(quad: projection.corners),
                  let polygons = warp.polygons(entry.polygons) else { return nil }
            // The existing layer renderer receives a pre-warped path with an identity box transform.
            return TrackedContour(id: projection.id,
                                  polygons: polygons.map { ContourGeometry.simplify($0, tolerance: 0.6) },
                                  referenceBox: CGRect(x: 0, y: 0, width: 1, height: 1), maskMs: 0)
        }
    }

    private func launch(snapshot: FrameSnapshot, jpeg: Data?, prompts: [String: LiveContourPrompt]) {
        let token = generation, processor = processor
        status = "კონტურების განახლება…"
        task = Task { [weak self] in
            do {
                let results = try await processor.process(snapshot: snapshot, jpeg: jpeg, prompts: prompts)
                guard let self, self.enabled, self.generation == token, !Task.isCancelled else { return }
                for result in results {
                    guard let polygons = result.polygons else {
                        if result.refresh { self.refreshRejected += 1 }
                        continue // Preserve the old plane contour on disagreement.
                    }
                    if result.refresh { self.refreshAccepted += 1 }
                    self.entries[result.id] = Entry(initialMask: self.entries[result.id]?.initialMask ?? result.mask,
                                                    polygons: polygons)
                }
                self.contours = self.entries.keys.sorted().map { id in
                    TrackedContour(id: id, polygons: self.entries[id]!.polygons,
                                   referenceBox: CGRect(x: 0, y: 0, width: 1, height: 1), maskMs: 0)
                }
                self.status = self.entries.isEmpty ? "კონტური მიუწვდომელია" : ""
                self.task = nil; self.lastFinished = CACurrentMediaTime()
            } catch {
                guard let self, self.generation == token, !Task.isCancelled else { return }
                self.status = "კონტური ვერ განახლდა"; self.task = nil; self.lastFinished = CACurrentMediaTime()
            }
        }
    }
}
