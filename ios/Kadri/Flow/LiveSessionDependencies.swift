import SwiftUI
import KadriCore
import ImageIO

struct FlowMarker: Identifiable {
    enum Tone { case brand, danger, neutral }
    let id: String
    let name: String
    let center: CGPoint
    let tone: Tone
    let tracked: Bool

    static func tone(id: String, step: Step?) -> Tone {
        if step?.avoid.contains(id) == true { return .danger }
        if step == nil || step?.focus.contains(id) == true { return .brand }
        return .neutral
    }

    static func make(parts: [Part], projections: [PartProjection], fallback: [(id: String, point: CGPoint)],
                     viewport: CGSize, imageSize: CGSize, step: Step?, anchoredIDs: Set<String> = []) -> [FlowMarker] {
        guard viewport.width > 0, viewport.height > 0, imageSize.width > 0, imageSize.height > 0 else { return [] }
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return parts.compactMap { part in
            guard part.hasValidBox else { return nil }
            let projection = projections.first { $0.id == part.id }
            if projection == nil && anchoredIDs.contains(part.id) { return nil }
            let fixed = fallback.first { $0.id == part.id }?.point
            let center = projection?.center ?? fixed ?? CGPoint(
                x: CGFloat(part.box[0] + part.box[2]) / 2000 * imageSize.width * scale + (viewport.width - imageSize.width * scale) / 2,
                y: CGFloat(part.box[1] + part.box[3]) / 2000 * imageSize.height * scale + (viewport.height - imageSize.height * scale) / 2)
            guard center.x.isFinite, center.y.isFinite else { return nil }
            return FlowMarker(id: part.id, name: part.name, center: center,
                              tone: tone(id: part.id, step: step), tracked: projection != nil)
        }
    }
}

@MainActor
final class LiveSessionDependencies: ObservableObject {
    let controller = ARSessionController()
    let anchors = PartAnchors()
    let model: SessionModel
    let mockImage: UIImage?
    @Published private(set) var masks: [String: Mask] = [:]
    @Published private(set) var segmentationStatus: String?
    private(set) var keyframe: Keyframe?
    private var jpeg: Data?
    private var segmentationTask: Task<Void, Never>?
    private var preparedResult: PartsResult?
    private var scanStarted: Date?
    private var partsReceived: Date?
    private var recordedFirstStep = false
    private let authError: (any Error)?
    var imageSize: CGSize { keyframe?.size ?? mockImage?.size ?? CGSize(width: 576, height: 768) }

    init() {
        let config = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "https://kadri-worker-staging.bekachkhirodze1.workers.dev")!)
        let storage: any TokenStorage
        do { storage = try DevAuth.storage(); authError = nil }
        catch { storage = InMemoryTokenStorage(); authError = error }
        model = SessionModel(api: KadriClient(config: config, auth: AuthStore(config: config, storage: storage)))
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--mock-keyframe"),
           let url = Bundle.main.url(forResource: "input", withExtension: "png", subdirectory: "sink") {
            mockImage = UIImage(contentsOfFile: url.path)
        } else { mockImage = nil }
        #else
        mockImage = nil
        #endif
    }

    func capture() async throws -> Data {
        if let authError { throw authError }
        clearCapture()
        scanStarted = Date()
        if let mockImage {
            let factor = 768 / max(mockImage.size.width, mockImage.size.height)
            let size = CGSize(width: (mockImage.size.width * factor).rounded(), height: (mockImage.size.height * factor).rounded())
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                mockImage.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = image.jpegData(compressionQuality: 0.85) else { throw KeyframePicker.Failure.encoding }
            jpeg = data
            return data
        }
        let previous = controller.keyframe?.timestamp
        await controller.capture()
        try Task.checkCancellation()
        guard let selected = controller.keyframe, selected.timestamp != previous else {
            throw SessionError.server(code: "keyframe_unavailable", message: controller.captureStatus)
        }
        keyframe = selected; jpeg = selected.jpegData
        return selected.jpegData
    }

    func phaseChanged() {
        if case .parts(let result) = model.phase, preparedResult != result {
            preparedResult = result
            partsReceived = Date()
            if let scanStarted { NSLog("FLOW submit_to_parts_ms=\(Int(Date().timeIntervalSince(scanStarted) * 1000))") }
            if let keyframe {
                anchors.place(keyframe: keyframe, parts: result.parts.map { ($0.id, $0.box) }, session: controller.session)
            }
            segment(parts: result.parts)
            // Start SSE immediately; SAM continues independently on its own actor.
            model.startSteps()
        }
        if model.currentStep != nil, !recordedFirstStep, let partsReceived {
            recordedFirstStep = true
            NSLog("FLOW parts_to_first_step_ms=\(Int(Date().timeIntervalSince(partsReceived) * 1000))")
        }
        switch model.phase {
        case .idle, .describing, .done: clearCapture()
        default: break
        }
    }

    func stop() {
        model.beginDescribing()
        clearCapture()
        controller.pause()
    }

    private func clearCapture() {
        segmentationTask?.cancel(); segmentationTask = nil
        anchors.clear(session: controller.session)
        keyframe = nil; jpeg = nil; masks = [:]; segmentationStatus = nil
        preparedResult = nil; partsReceived = nil; recordedFirstStep = false
    }

    private func segment(parts: [Part]) {
        guard let jpeg else { return }
        segmentationTask = Task { [weak self] in
            do {
                let result = try await Self.segmentImage(jpeg, parts: parts)
                try Task.checkCancellation()
                self?.masks = result
            } catch is CancellationError { }
            catch { self?.segmentationStatus = "კონტურები მიუწვდომელია" }
        }
    }

    nonisolated private static func segmentImage(_ data: Data, parts: [Part]) async throws -> [String: Mask] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SegmentationError.imageDecodeFailed }
        let segmenter = try Segmenter()
        let embedding = try await segmenter.embed(image)
        var masks: [String: Mask] = [:]
        for part in parts {
            try Task.checkCancellation()
            masks[part.id] = try await segmenter.mask(embedding: embedding, box: PartBox(part))
        }
        return masks
    }
}

