import SwiftUI
import KadriCore
import ImageIO

@MainActor
final class PhotoSession: ObservableObject {
    let model: SessionModel
    let isMock: Bool
    @Published private(set) var image: UIImage?
    @Published private(set) var meshes: [TrackedMesh] = []
    @Published private(set) var segmentationStatus: String?
    @Published var selectionError: String?
    private var jpeg: Data?
    private var segmentation: Task<Void, Never>?
    private var preparedResult: PartsResult?
    private let authError: SessionError?
    var imageSize: CGSize { image?.size ?? CGSize(width: 1024, height: 1536) }

    init(api: (any KadriAPI)? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        isMock = ProcessInfo.processInfo.arguments.contains("--photo-mock")
        #else
        isMock = false
        #endif
        let config = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "https://kadri-worker-staging.bekachkhirodze1.workers.dev")!)
        let storage: any TokenStorage
        do { storage = try DevAuth.storage(); authError = nil }
        catch { storage = InMemoryTokenStorage(); authError = SessionError(error) }
        let live = { KadriClient(config: config, auth: AuthStore(config: config, storage: storage)) }
        #if DEBUG
        model = SessionModel(api: api ?? (isMock ? MockKadriAPI(scanDelay: .seconds(1.2), stepDelay: .seconds(2.5)) : live()))
        #else
        model = SessionModel(api: api ?? live())
        #endif
        model.beginDescribing()
    }

    func select(_ source: UIImage) {
        cancelSegmentation()
        if case .describing = model.phase {} else { model.beginDescribing() }
        // Rasterize orientation once. Detector, SAM and display all consume this same JPEG.
        let factor = min(1, 1536 / max(source.size.width, source.size.height))
        let size = CGSize(width: (source.size.width * factor).rounded(), height: (source.size.height * factor).rounded())
        guard size.width > 0, size.height > 0 else { selectionError = "ფოტოს წაკითხვა ვერ მოხერხდა."; return }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let data = normalized.jpegData(compressionQuality: 0.88), let decoded = UIImage(data: data) else {
            selectionError = "ფოტოს დამუშავება ვერ მოხერხდა."; return
        }
        jpeg = data; image = decoded; selectionError = nil
    }

    func submit(_ text: String) {
        guard let jpeg else { return }
        model.updateText(text)
        let failure = isMock ? nil : authError
        model.submit { if let failure { throw failure }; return jpeg }
    }

    func phaseChanged() {
        switch model.phase {
        case .parts(let result) where preparedResult != result:
            preparedResult = result
            segment(result.parts)
            // Start SSE immediately; SAM continues independently on its own actor.
            model.startSteps()
        case .idle, .describing, .done:
            cancelSegmentation()
            preparedResult = nil
        default: break
        }
    }

    func retake() {
        cancelSegmentation()
        image = nil; jpeg = nil; preparedResult = nil
        model.beginDescribing()
    }

    private func cancelSegmentation() {
        segmentation?.cancel(); segmentation = nil
        meshes = []; segmentationStatus = nil
    }

    private func segment(_ parts: [Part]) {
        guard let jpeg else { return }
        segmentation?.cancel()
        meshes = []; segmentationStatus = "ნაწილებს ვყოფ…"
        segmentation = Task { [weak self] in
            do {
                try await Self.segment(jpeg, parts: parts) { [weak self] mesh in
                    guard !Task.isCancelled else { return }
                    await self?.receive(mesh)
                }
                try Task.checkCancellation()
                self?.segmentationStatus = nil
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { self?.segmentationStatus = "ბადე ვერ მომზადდა. ნაწილები ეტიკეტებითაა მონიშნული." }
            }
        }
    }

    private func receive(_ mesh: TrackedMesh) {
        guard !Task.isCancelled else { return }
        meshes.append(mesh)
    }

    nonisolated private static func segment(_ data: Data, parts: [Part],
        receive: @Sendable (TrackedMesh) async -> Void) async throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SegmentationError.imageDecodeFailed }
        let segmenter = try await Segmenter.shared()
        try Task.checkCancellation()
        let embedding = try await segmenter.embed(image)
        let cache = TrackedMeshCache()
        for part in parts where part.hasValidBox {
            try Task.checkCancellation()
            let mask = try await segmenter.mask(embedding: embedding, box: PartBox(part))
            try Task.checkCancellation()
            let b = part.box
            let contour = TrackedContour(id: part.id, polygons: try MaskContours.extract(mask),
                referenceBox: CGRect(x: CGFloat(b[0])/1000, y: CGFloat(b[1])/1000,
                                     width: CGFloat(b[2]-b[0])/1000, height: CGFloat(b[3]-b[1])/1000),
                maskMs: mask.decodeMs + mask.postMs)
            let mesh = await cache.mesh(for: contour)
            try Task.checkCancellation()
            await receive(mesh)
        }
    }

    #if DEBUG
    func selectDemo() {
        if let url = Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) { select(image) }
        else { selectionError = "სატესტო ფოტო ვერ მოიძებნა." }
    }
    #endif
}
