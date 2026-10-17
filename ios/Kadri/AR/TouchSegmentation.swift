import Foundation
import CoreGraphics
import ImageIO
import Combine

struct TouchFrame: Sendable {
    let jpegData: Data
    let reference: PartReference
    let timestamp: TimeInterval
    let displayTransform: CGAffineTransform
}

enum TouchGeometry {
    /// ARKit's sensor-normalized display transform includes orientation and aspect-fill crop.
    static func pixel(_ point: CGPoint, viewport: CGSize, imageSize: CGSize,
                      displayTransform: CGAffineTransform) -> CGPoint? {
        guard viewport.width > 0, viewport.height > 0, imageSize.width > 0, imageSize.height > 0,
              point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0,
              point.x < viewport.width, point.y < viewport.height,
              abs(displayTransform.a*displayTransform.d-displayTransform.b*displayTransform.c) > 1e-9 else { return nil }
        let sensor = CGPoint(x: point.x/viewport.width, y: point.y/viewport.height).applying(displayTransform.inverted())
        // KeyframePicker rotates sensor pixels clockwise into portrait JPEG coordinates.
        let pixel = CGPoint(x: (1-sensor.y)*imageSize.width, y: sensor.x*imageSize.height)
        guard pixel.x >= 0, pixel.y >= 0, pixel.x <= imageSize.width, pixel.y <= imageSize.height else { return nil }
        return CGPoint(x: min(pixel.x, imageSize.width-1), y: min(pixel.y, imageSize.height-1))
    }

    static func bounds(_ mask: Mask) -> PartBox? {
        var x0 = mask.width, y0 = mask.height, x1 = -1, y1 = -1
        for y in 0..<mask.height { for x in 0..<mask.width where mask.pixels[y*mask.width+x] > 0 {
            x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y)
        }}
        guard x1 >= x0, y1 >= y0 else { return nil }
        return PartBox(x0: x0*1000/mask.width, y0: y0*1000/mask.height,
                       x1: Int(ceil(Double(x1+1)*1000/Double(mask.width))),
                       y1: Int(ceil(Double(y1+1)*1000/Double(mask.height))))
    }

    static func samples(_ mask: Mask) -> [CGPoint] {
        // Uniformly spread foreground samples; avoid taking only the first mask rows.
        let step = max(1, mask.area/81)
        var result: [CGPoint] = [], count = 0
        for i in mask.pixels.indices where mask.pixels[i] > 0 {
            if count % step == 0, result.count < 81 { result.append(CGPoint(x: i%mask.width, y: i/mask.width)) }
            count += 1
        }
        return result
    }
}

private struct TouchResult: Sendable {
    let box: PartBox
    let samples: [CGPoint]
    let contour: TrackedContour
    let embedMs: Double
    let decodeMs: Double
    let contourMs: Double
}

private actor TouchProcessor {
    private var model: Segmenter?
    private var cached: (timestamp: TimeInterval, embedding: Embedding)?

    func reset() { cached = nil }

    func process(_ frame: TouchFrame, point: CGPoint, id: String) async throws -> TouchResult {
        try Task.checkCancellation()
        let segmenter: Segmenter
        if let model { segmenter = model }
        else {
            segmenter = try await Segmenter.shared()
            model = segmenter
        }
        let start = Clock.now
        let embedding: Embedding
        if let cached, cached.timestamp == frame.timestamp { embedding = cached.embedding }
        else {
            guard let source = CGImageSourceCreateWithData(frame.jpegData as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SegmentationError.imageDecodeFailed }
            embedding = try await segmenter.embed(image)
            try Task.checkCancellation()
            cached = (frame.timestamp, embedding)
        }
        let embedMs = Clock.ms(since: start)
        let mask = try await segmenter.maskFromPoint(embedding: embedding, point: point)
        try Task.checkCancellation()
        let contourStart = Clock.now
        guard let box = TouchGeometry.bounds(mask) else { throw SegmentationError.unexpectedOutput("empty point mask") }
        let polygons = try MaskContours.extract(mask)
        guard !polygons.isEmpty else { throw SegmentationError.unexpectedOutput("empty point contour") }
        let rect = CGRect(x: CGFloat(box.x0)/1000, y: CGFloat(box.y0)/1000,
                          width: CGFloat(box.x1-box.x0)/1000, height: CGFloat(box.y1-box.y0)/1000)
        let samples = TouchGeometry.samples(mask)
        return TouchResult(box: box, samples: samples,
                           contour: TrackedContour(id: id, polygons: polygons, referenceBox: rect, maskMs: mask.decodeMs+mask.postMs),
                           embedMs: embedMs, decodeMs: mask.decodeMs+mask.postMs, contourMs: Clock.ms(since: contourStart))
    }
}

@MainActor
final class TouchSegmentation: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var status = "შეეხეთ საგანს"
    @Published private(set) var timings = ""
    private let processor = TouchProcessor()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var nextID = 1

    func clear(controller: ARSessionController, anchors: PartAnchors, tracker: PartTracker) {
        generation += 1; task?.cancel(); task = nil; busy = false
        anchors.clear(session: controller.session); tracker.stop()
        status = "შეეხეთ საგანს"; timings = ""
        Task { await processor.reset() }
    }

    func touch(_ point: CGPoint, viewport: CGSize, controller: ARSessionController,
               anchors: PartAnchors, tracker: PartTracker) {
        guard !busy else { return }
        busy = true; status = "სეგმენტაცია…"
        let token = generation, id = "t\(nextID)", start = Clock.now
        nextID += 1
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await controller.captureTouch(viewport: viewport)
                let keyframeMs = Clock.ms(since: start)
                guard let pixel = TouchGeometry.pixel(point, viewport: viewport, imageSize: frame.reference.size,
                                                       displayTransform: frame.displayTransform) else {
                    throw SegmentationError.unexpectedOutput("touch outside keyframe")
                }
                let result = try await processor.process(frame, point: pixel, id: id)
                try Task.checkCancellation()
                guard generation == token else { return }
                anchors.append(reference: frame.reference, parts: [(id, result.box.values)],
                               maskPixels: [id: result.samples], session: controller.session)
                tracker.inject(result.contour, embedMs: result.embedMs)
                timings = String(format: "კადრი %.1f · embed %.1f · decode %.1f · კონტური %.1f · სულ %.1f ms",
                                 keyframeMs, result.embedMs, result.decodeMs, result.contourMs, Clock.ms(since: start))
                status = anchors.unanchored.contains(id) ? "\(id) · 2D — ზედაპირი ვერ მოიძებნა" : "\(id) მიბმულია"
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                status = error is KeyframePicker.Failure ? "გააჩერეთ კამერა და დაელოდეთ ნორმალურ ტრეკინგს" : error.localizedDescription
            }
            if generation == token { busy = false; task = nil }
        }
    }
}
