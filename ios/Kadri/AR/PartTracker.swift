@preconcurrency import ARKit
import CoreImage
import ImageIO
import KadriCore
import Combine
import os

private let samLog = Logger(subsystem: "ge.kadri", category: "ar")

private struct ContourBatch: Sendable {
    let contours: [TrackedContour]
    let embedMs: Double
}

/// Serial, off-main image conversion, model loading, inference and contour extraction.
private actor ContourProcessor {
    private var segmenter: Segmenter?
    private let context = CIContext(options: [.cacheIntermediates: false])

    func process(snapshot: FrameSnapshot, jpeg: Data?, boxes: [String: CGRect],
                 onContour: @Sendable (TrackedContour) async -> Void) async throws -> ContourBatch {
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
        let model: Segmenter
        if let segmenter { model = segmenter }
        else {
            #if targetEnvironment(simulator)
            model = try Segmenter(computeUnits: .cpuOnly)
            #else
            model = try Segmenter()
            #endif
            segmenter = model
            samLog.notice("ge.kadri sam-load ms=\(Int(model.loadMs))")
        }
        let embedding = try await model.embed(image)
        var contours: [TrackedContour] = []
        for id in boxes.keys.sorted() {
            try Task.checkCancellation()
            let box = boxes[id]!
            let prompt = PartBox(x0: max(0, Int(floor(box.minX*1000))), y0: max(0, Int(floor(box.minY*1000))),
                                 x1: min(1000, Int(ceil(box.maxX*1000))), y1: min(1000, Int(ceil(box.maxY*1000))))
            guard prompt.isValid else { continue }
            let mask = try await model.mask(embedding: embedding, box: prompt)
            try Task.checkCancellation()
            contours.append(TrackedContour(id: id, polygons: try MaskContours.extract(mask), referenceBox: box,
                                           maskMs: mask.decodeMs + mask.postMs))
            await onContour(contours.last!)
        }
        return ContourBatch(contours: contours, embedMs: embedding.preMs + embedding.encodeMs)
    }
}

@MainActor
final class PartTracker: ObservableObject {
    @Published private(set) var contours: [TrackedContour] = [] {
        didSet { rebuildMeshes() }
    }
    @Published private(set) var meshes: [TrackedMesh] = []
    private var meshCache = TrackedMeshCache()
    private var meshTask: Task<Void, Never>?

    private func rebuildMeshes() {
        meshTask?.cancel()
        let contours = contours, cache = meshCache
        if contours.isEmpty { meshes = []; return }
        meshTask = Task { [weak self] in
            var result: [TrackedMesh] = []
            for contour in contours {
                guard !Task.isCancelled else { return }
                result.append(await cache.mesh(for: contour))
            }
            guard !Task.isCancelled else { return }
            self?.meshes = result
        }
    }
    @Published private(set) var embedMs: Double = 0
    @Published private(set) var status = ""
    var interval = 30
    private let processor = ContourProcessor()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var frameCount = 0
    private var referenceBoxes: [String: CGRect] = [:]
    private var enabled = false

    func start(keyframe: Keyframe, placements: [PartPlacement]) {
        stop()
        enabled = true
        let boxes = Dictionary(uniqueKeysWithValues: placements.map { placement in
            let b = placement.box
            return (placement.id, CGRect(x: CGFloat(b[0])/1000, y: CGFloat(b[1])/1000,
                                         width: CGFloat(b[2]-b[0])/1000, height: CGFloat(b[3]-b[1])/1000))
        })
        guard !boxes.isEmpty else { status = "ჯერ მიაბით სატესტო box-ები"; return }
        launch(snapshot: keyframe.snapshot, jpeg: keyframe.jpegData, boxes: boxes)
    }

    /// Adopt a completed point mask without another encoder/decoder pass.
    /// Cancel an older batch so it cannot overwrite the newly injected contour.
    func inject(_ contour: TrackedContour, embedMs: Double) {
        generation += 1; task?.cancel(); task = nil
        enabled = true; frameCount = 0
        contours.removeAll { $0.id == contour.id }; contours.append(contour)
        referenceBoxes[contour.id] = contour.referenceBox
        self.embedMs = embedMs; status = ""
    }

    func stop() {
        enabled = false; generation += 1; task?.cancel(); task = nil
        meshCache = TrackedMeshCache()
        contours = []; referenceBoxes = [:]; frameCount = 0; embedMs = 0; status = ""
    }

    /// Use an uncropped portrait viewport to keep prompts in the same space as the oriented image.
    func update(snapshot: FrameSnapshot, anchors: PartAnchors) {
        guard enabled else { return }
        frameCount += 1
        guard task == nil, case .normal = snapshot.frame.camera.trackingState else { return }
        let resolution = snapshot.frame.camera.imageResolution
        let viewport = CGSize(width: resolution.height, height: resolution.width)
        let projections = anchors.projections(frame: snapshot.frame, viewport: viewport, scale: 1)
        let boxes = Self.boxes(projections, normalizedBy: viewport)
        guard !boxes.isEmpty else { return }
        let needsUpdate = boxes.contains { id, box in
            guard let reference = referenceBoxes[id] else { return true }
            return ContourGeometry.shouldResegment(frames: frameCount, interval: interval, reference: reference, current: box)
        }
        if needsUpdate { launch(snapshot: snapshot, jpeg: nil, boxes: boxes) }
    }

    static func boxes(_ projections: [PartProjection], normalizedBy size: CGSize? = nil) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        for projection in projections {
            var box = ContourGeometry.bounds(projection.corners)
            if let size {
                box = CGRect(x: box.minX/size.width, y: box.minY/size.height,
                             width: box.width/size.width, height: box.height/size.height)
                // Partial visibility is fine; entirely offscreen prompts are omitted.
                if box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)).isEmpty { continue }
            }
            if ContourGeometry.valid(box) { result[projection.id] = box }
        }
        return result
    }

    private func receive(_ contour: TrackedContour, token: Int) {
        guard enabled, generation == token else { return }
        contours = contours.filter { $0.id != contour.id } + [contour]
    }

    private func launch(snapshot: FrameSnapshot, jpeg: Data?, boxes: [String: CGRect]) {
        generation += 1
        let token = generation, processor = processor
        frameCount = 0
        status = "კონტურების განახლება…"
        task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                try await processor.process(snapshot: snapshot, jpeg: jpeg, boxes: boxes) { [weak self] contour in
                    await self?.receive(contour, token: token)
                }
            }
            do {
                let result = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                guard let self, self.enabled, self.generation == token, !Task.isCancelled else { return }
                // Preserve injected 2D contours that have no world projection in this batch.
                self.contours.removeAll { boxes[$0.id] != nil }
                self.contours.append(contentsOf: result.contours); self.embedMs = result.embedMs
                self.referenceBoxes.merge(boxes, uniquingKeysWith: { _, new in new })
                self.status = ""; self.task = nil
            } catch {
                guard let self, self.enabled, self.generation == token, !Task.isCancelled else { return }
                self.status = error.localizedDescription; self.task = nil
                // Retry only after the configured frame interval, not on every frame.
                self.referenceBoxes = boxes; self.frameCount = 0
            }
        }
    }
}
