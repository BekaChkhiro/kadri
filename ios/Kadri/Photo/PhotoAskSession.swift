import SwiftUI
import KadriCore

struct PhotoAskSelection: Identifiable {
    let id = UUID()
    let partId: String?
    let label: String?
    let box: [Int]
    var contour: TrackedContour? = nil
}

enum PhotoAskGeometry {
    static func select(point: CGPoint, imageSize: CGSize, transform: CGAffineTransform, parts: [Part]) -> PhotoAskSelection? {
        guard imageSize.width > 0, imageSize.height > 0, abs(transform.a * transform.d - transform.b * transform.c) > 0.000001 else { return nil }
        let pixel = point.applying(transform.inverted())
        guard CGRect(origin: .zero, size: imageSize).contains(pixel) else { return nil }
        let boxes = PhotoGeometry.boxes(parts: parts, imageSize: imageSize, transform: transform)
        // In nested boxes choose the smallest part under the finger.
        if let part = parts.filter({ boxes[$0.id]?.contains(point) == true }).min(by: {
            let a = boxes[$0.id]!, b = boxes[$1.id]!
            return a.width * a.height < b.width * b.height
        }) { return PhotoAskSelection(partId: part.id, label: part.name, box: part.box) }
        let x = Int(pixel.x / imageSize.width * 1000), y = Int(pixel.y / imageSize.height * 1000)
        let x0 = min(800, max(0, x - 100)), y0 = min(800, max(0, y - 100))
        return PhotoAskSelection(partId: nil, label: nil, box: [x0, y0, x0 + 200, y0 + 200])
    }

    static func bounds(_ mask: Mask) -> [Int]? {
        guard mask.width > 0, mask.height > 0, mask.pixels.count == mask.width * mask.height else { return nil }
        return TouchGeometry.bounds(mask)?.values
    }

    static func rect(_ box: [Int], imageSize: CGSize, transform: CGAffineTransform) -> CGRect {
        CGRect(x: CGFloat(box[0]) / 1000 * imageSize.width, y: CGFloat(box[1]) / 1000 * imageSize.height,
               width: CGFloat(box[2] - box[0]) / 1000 * imageSize.width,
               height: CGFloat(box[3] - box[1]) / 1000 * imageSize.height).applying(transform)
    }
}

private actor PhotoAskSegmenter {
    func select(image: CGImage, point: CGPoint) async throws -> PhotoAskSelection? {
        let model = try await Segmenter.shared() // Existing lazy CPU-only model configuration.
        try Task.checkCancellation()
        let embedding = try await model.embed(image)
        try Task.checkCancellation()
        let mask = try await model.maskFromPoint(embedding: embedding, point: point)
        try Task.checkCancellation()
        guard let box = PhotoAskGeometry.bounds(mask) else { return nil }
        let polygons = (try? MaskContours.extract(mask)) ?? []
        let rect = PhotoAskGeometry.rect(box, imageSize: CGSize(width: 1, height: 1), transform: .identity)
        return PhotoAskSelection(partId: nil, label: nil, box: box,
            contour: polygons.isEmpty ? nil : TrackedContour(id: "ask", polygons: polygons, referenceBox: rect, maskMs: mask.decodeMs + mask.postMs))
    }
}

@MainActor
final class PhotoAskSession: ObservableObject {
    enum Phase: Equatable { case idle, loading, result(AskResult), error(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selection: PhotoAskSelection?
    @Published var showingSheet = false
    private var work: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    private let segmenter = PhotoAskSegmenter()
    private let suppliedAPI: (any KadriAPI)?

    init(api: (any KadriAPI)? = nil) { suppliedAPI = api }

    func select(point: CGPoint, image: UIImage, transform: CGAffineTransform, parts: [Part]) {
        dismiss()
        guard let fallback = PhotoAskGeometry.select(point: point, imageSize: image.size, transform: transform, parts: parts) else { return }
        selection = fallback
        if fallback.partId != nil { showingSheet = true; return }
        guard let cg = image.cgImage else { showingSheet = true; return }
        let pixel = point.applying(transform.inverted())
        let samPoint = CGPoint(x: pixel.x * CGFloat(cg.width) / image.size.width, y: pixel.y * CGFloat(cg.height) / image.size.height)
        let token = generation
        // Do not await a task group: Core ML inference cannot be interrupted midway.
        // Publish the fallback independently at the deadline and reject late results.
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, generation == token else { return }
            generation = UUID(); work?.cancel(); showingSheet = true
        }
        work = Task { [weak self, segmenter] in
            let result = try? await segmenter.select(image: cg, point: samPoint)
            guard !Task.isCancelled, let self, generation == token else { return }
            deadline?.cancel()
            if let result { selection = result }
            showingSheet = true
        }
    }

    func submit(question: String, image: UIImage, parts: [Part], context: AskContext?) {
        let question = String(question.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
        guard !question.isEmpty, let selection else { return }
        work?.cancel(); generation = UUID()
        let token = generation
        phase = .loading
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let api = try makeAPI()
                // Preserve the entire displayed photo, its orientation, and the normalized boxes.
                let scale = min(1, 768 / max(image.size.width, image.size.height))
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                guard let jpeg = resized.jpegData(compressionQuality: 0.85) else { throw SessionError.server(code: "image", message: "ფოტოს წაკითხვა ვერ მოხერხდა") }
                let provider = UserDefaults.standard.string(forKey: "photoAIProvider").flatMap(AIProvider.init(rawValue:)) ?? .gemini
                let result = try await api.ask(keyframe: jpeg, question: question, box: selection.box, partId: selection.partId,
                                               parts: parts, context: context, provider: provider)
                guard !Task.isCancelled, generation == token else { return }
                phase = .result(result)
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                phase = .error(error.localizedDescription)
            }
        }
    }

    func cancel() {
        generation = UUID(); work?.cancel(); deadline?.cancel(); work = nil; deadline = nil; phase = .idle
    }
    func dismiss() { cancel(); showingSheet = false; selection = nil }

    private func makeAPI() throws -> any KadriAPI {
        if let suppliedAPI { return suppliedAPI }
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--photo-mock") || ProcessInfo.processInfo.arguments.contains("--photo-diagnostic") { return MockKadriAPI() }
        #endif
        let config = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "https://kadri-worker-staging.bekachkhirodze1.workers.dev")!)
        let storage = try DevAuth.storage()
        return KadriClient(config: config, auth: LiveAuth.store(config: config, storage: storage))
    }
}
