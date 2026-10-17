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
    /// When the first description was sent; the done screen counts the session's minutes from it.
    @Published private(set) var startedAt: Date?
    private var jpeg: Data?
    /// Worker `/ai/parts` rejects keyframes whose long side exceeds 768 px; boxes are 0–1000 so they still map onto `jpeg`.
    /// Both copies are the same centre square, so the photo always fills a square photo area.
    private var apiJPEG: Data?
    private var segmentation: Task<Void, Never>?
    private var preparedResult: PartsResult?
    private let authError: SessionError?
    /// A finished earlier round's photo; `rounds[i]` is round `i + 1`. The current round lives in `image`/`jpeg`/`meshes`.
    private struct PhotoRound { let image: UIImage; let jpeg: Data; let apiJPEG: Data; let meshes: [TrackedMesh] }
    private var rounds: [PhotoRound] = []
    var imageSize: CGSize { image?.size ?? CGSize(width: 1024, height: 1024) }

    init(api: (any KadriAPI)? = nil) {
        #if DEBUG && targetEnvironment(simulator)
        isMock = ProcessInfo.processInfo.arguments.contains("--photo-mock") || ProcessInfo.processInfo.arguments.contains("--photo-diagnostic")
        #else
        isMock = false
        #endif
        let config = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "https://kadri-worker-staging.bekachkhirodze1.workers.dev")!)
        let storage: any TokenStorage
        do { storage = try DevAuth.storage(); authError = nil }
        catch { storage = InMemoryTokenStorage(); authError = SessionError(error) }
        let live = { KadriClient(config: config, auth: LiveAuth.store(config: config, storage: storage)) }
        #if DEBUG
        #if targetEnvironment(simulator)
        let multiPhoto = ProcessInfo.processInfo.arguments.contains("--photo-multi")
        #else
        let multiPhoto = false
        #endif
        model = SessionModel(api: api ?? (isMock ? MockKadriAPI(scanDelay: .seconds(1.2), stepDelay: .seconds(2.5), multiPhoto: multiPhoto, diagnostic: ProcessInfo.processInfo.arguments.contains("--photo-diagnostic"), answerThenPhoto: ProcessInfo.processInfo.arguments.contains("--photo-answer-then-photo"), answerOnSecondPhoto: ProcessInfo.processInfo.arguments.contains("--photo-answer-on-second-photo")) : live()))
        #else
        model = SessionModel(api: api ?? live())
        #endif
        model.beginDescribing()
    }

    func select(_ source: UIImage) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--photo-reset-trace") {
            print("PHOTO_RESET_TRACE \(#function)\n" + Thread.callStackSymbols.joined(separator: "\n"))
        }
        #endif
        cancelSegmentation()
        if case .describing = model.phase {} else { model.beginDescribing() }
        rounds = []
        guard let prepared = prepare(source) else { return }
        jpeg = prepared.jpeg; apiJPEG = prepared.apiJPEG; image = prepared.image; selectionError = nil
    }

    /// Square-crop and rasterize orientation once. SAM and display consume the ≤1536 px JPEG; the detector gets a ≤768 px copy.
    private func prepare(_ source: UIImage) -> (jpeg: Data, apiJPEG: Data, image: UIImage)? {
        guard source.size.width > 0, source.size.height > 0 else { selectionError = "ფოტოს წაკითხვა ვერ მოხერხდა."; return nil }
        guard let data = Self.squareJPEG(source, maxSide: 1536), let decoded = UIImage(data: data),
              let apiData = Self.squareJPEG(source, maxSide: 768) else {
            selectionError = "ფოტოს დამუშავება ვერ მოხერხდა."; return nil
        }
        return (data, apiData, decoded)
    }

    /// Files the current photo as a finished round and scans `source` for the round the model asked for.
    func continueWithPhoto(_ source: UIImage) {
        guard model.canContinueWithPhoto, let image, let jpeg, let apiJPEG,
              let prepared = prepare(source) else { return }
        rounds.append(PhotoRound(image: image, jpeg: jpeg, apiJPEG: apiJPEG, meshes: meshes))
        cancelSegmentation()
        preparedResult = nil
        self.jpeg = prepared.jpeg; self.apiJPEG = prepared.apiJPEG; self.image = prepared.image; selectionError = nil
        let failure = isMock ? nil : authError
        let keyframe = prepared.apiJPEG
        model.continueWithPhoto { if let failure { throw failure }; return keyframe }
    }

    /// The photo of the round the current step belongs to; earlier rounds come back after `previous()`.
    var displayedImage: UIImage? {
        let number = model.displayedRound
        return number < model.round && rounds.indices.contains(number - 1) ? rounds[number - 1].image : image
    }

    var displayedMeshes: [TrackedMesh] {
        let number = model.displayedRound
        return number < model.round && rounds.indices.contains(number - 1) ? rounds[number - 1].meshes : meshes
    }

    /// The centre square of `source`, upright, at most `maxSide` px per side — crop, scale and orientation in one draw.
    static func squareJPEG(_ source: UIImage, maxSide: CGFloat) -> Data? {
        let w = source.size.width, h = source.size.height
        guard w > 0, h > 0, maxSide > 0 else { return nil }
        let side = min(maxSide, min(w, h)).rounded(.down)
        let factor = side / min(w, h)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            source.draw(in: CGRect(x: -(w * factor - side) / 2, y: -(h * factor - side) / 2,
                                   width: w * factor, height: h * factor))
        }.jpegData(compressionQuality: 0.88)
    }

    /// Opens a bundled example photo with its description already typed.
    func selectExample(_ example: PhotoExample) {
        guard let source = example.image() else { selectionError = "ფოტოს წაკითხვა ვერ მოხერხდა."; return }
        select(source)
        guard image != nil else { return }
        model.updateText(example.prefill)
    }

    /// Whole minutes since the first description, at least one.
    func minutes(at now: Date = Date()) -> Int {
        guard let startedAt else { return 1 }
        return max(1, Int(ceil(now.timeIntervalSince(startedAt) / 60)))
    }

    func submit(_ text: String, provider: AIProvider = .astra) {
        guard let apiJPEG else { return }
        if startedAt == nil { startedAt = Date() }
        model.updateText(text)
        let failure = isMock ? nil : authError
        model.submit(provider: provider) { if let failure { throw failure }; return apiJPEG }
    }

    func phaseChanged() {
        // Cancelling a later round's photo returns the model to the previous round; its photo becomes current again.
        if rounds.count >= model.round, let last = rounds.popLast() {
            cancelSegmentation()
            image = last.image; jpeg = last.jpeg; apiJPEG = last.apiJPEG; meshes = last.meshes
            preparedResult = model.partsResult
        }
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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--photo-reset-trace") {
            print("PHOTO_RESET_TRACE \(#function)\n" + Thread.callStackSymbols.joined(separator: "\n"))
        }
        #endif
        cancelSegmentation()
        image = nil; jpeg = nil; apiJPEG = nil; preparedResult = nil; rounds = []; startedAt = nil
        model.beginDescribing()
    }

    private func cancelSegmentation() {
        segmentation?.cancel(); segmentation = nil
        meshes = []; segmentationStatus = nil
    }

    private func segment(_ parts: [Part]) {
        guard let jpeg else { return }
        segmentation?.cancel()
        meshes = []; segmentationStatus = "ვასკანერებ…"
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
                if !Task.isCancelled { self?.segmentationStatus = "ბადის გარეშე" }
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

    /// The simulator has no camera; the same demo photo is enough for a later round.
    func continueWithDemo() {
        if let url = Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) { continueWithPhoto(image) }
        else { selectionError = "სატესტო ფოტო ვერ მოიძებნა." }
    }
    #endif
}
