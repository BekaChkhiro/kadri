import SwiftUI
import ARKit
import AVFoundation
import KadriCore

@MainActor
final class LiveCameraSession: ObservableObject {
    let controller = ARSessionController()
    let anchors = PartAnchors()
    let tracker = PartTracker()
    let model: SessionModel
    @Published private(set) var needsRecognition = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var waitingForKeyframe = true
    @Published var selectedID: String?
    @Published var instructions = ""
    private var keyframe: Keyframe?
    private var preparedResult: PartsResult?
    private var captureTask: Task<Void, Never>?
    private var generation = 0
    private var running = false
    private var started = false
    private var lastCaptureAttempt: TimeInterval = 0
    private var lastTrackedTimestamp: TimeInterval?
    private let authError: SessionError?

    init(api: (any KadriAPI)? = nil) {
        let config = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "https://kadri-worker-staging.bekachkhirodze1.workers.dev")!)
        let storage: any TokenStorage
        do { storage = try DevAuth.storage(); authError = nil }
        catch { storage = InMemoryTokenStorage(); authError = api == nil ? SessionError(error) : nil }
        model = SessionModel(api: api ?? KadriClient(config: config, auth: LiveAuth.store(config: config, storage: storage)),
                             scanTimeout: .seconds(config.scanTimeout))
        model.beginDescribing()
    }

    func start() async {
        guard controller.supported, !running else { return }
        generation += 1
        let token = generation
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard token == generation, !Task.isCancelled else { return }
        permissionDenied = !granted
        guard granted else { return }
        running = true
        if started { needsRecognition = true; waitingForKeyframe = false }
        started = true
        controller.start()
        // The consumer flow needs real raycast surfaces on non-LiDAR devices;
        // it deliberately cannot use PartAnchors' debug depth guesses.
        if let configuration = controller.session.configuration as? ARWorldTrackingConfiguration {
            configuration.planeDetection = [.horizontal, .vertical]
            controller.session.run(configuration)
        }
    }

    func stop() {
        running = false
        clearRecognition()
        needsRecognition = true; waitingForKeyframe = false
        controller.pause()
    }

    func recognizeAgain() {
        guard running else { return }
        clearRecognition()
        needsRecognition = false; waitingForKeyframe = true
        lastCaptureAttempt = 0
    }

    private func clearRecognition() {
        generation += 1
        captureTask?.cancel(); captureTask = nil
        model.beginDescribing()
        tracker.stop()
        anchors.clear(session: controller.session)
        keyframe = nil; preparedResult = nil; selectedID = nil; lastTrackedTimestamp = nil
    }

    private func invalidate() {
        clearRecognition()
        needsRecognition = true; waitingForKeyframe = false
    }

    /// Called for each new AR frame, and on a timer to catch frozen frame delivery.
    func update(now: TimeInterval = CACurrentMediaTime()) {
        guard running else { return }
        guard let snapshot = controller.latest else {
            if keyframe != nil { invalidate() }
            return
        }
        let normal: Bool
        if case .normal = snapshot.frame.camera.trackingState { normal = true } else { normal = false }
        if let keyframe {
            guard normal, now - snapshot.timestamp < 0.5,
                  LiveTrackingPolicy.sameView(reference: keyframe.snapshot.frame.camera.transform,
                                              current: snapshot.frame.camera.transform) else {
                invalidate(); return
            }
            if lastTrackedTimestamp != snapshot.timestamp {
                lastTrackedTimestamp = snapshot.timestamp
                tracker.update(snapshot: snapshot, anchors: anchors)
            }
        }
        guard waitingForKeyframe, normal, captureTask == nil,
              now - snapshot.timestamp < 0.5, snapshot.timestamp - lastCaptureAttempt >= 0.6 else { return }
        lastCaptureAttempt = snapshot.timestamp
        let token = generation
        let previous = controller.keyframe?.timestamp
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.controller.capture()
            guard !Task.isCancelled, token == self.generation, self.running else { return }
            self.captureTask = nil
            guard let selected = self.controller.keyframe,
                  LiveTrackingPolicy.freshKeyframe(timestamp: selected.timestamp, previous: previous,
                                                   now: CACurrentMediaTime()) else { return }
            self.keyframe = selected
            self.submit(keyframe: selected.jpegData)
        }
    }

    /// The same submission path is exercised with JPEG fixtures and a mock API in hosted tests.
    func submit(keyframe jpeg: Data) {
        waitingForKeyframe = false
        model.beginDescribing()
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateText(text.isEmpty ? "მაჩვენე ობიექტის ხილული ნაწილები და ამიხსენი მათი დანიშნულება." : text)
        let error = authError
        model.submit(provider: .gemini) {
            if let error { throw error }
            return jpeg
        }
    }

    func phaseChanged() {
        guard case .parts(let result) = model.phase, preparedResult != result, let keyframe,
              !needsRecognition, running else { return }
        preparedResult = result
        anchors.place(keyframe: keyframe, parts: result.parts.map { ($0.id, $0.box) }, session: controller.session)
        // PartAnchors' debug-only feature/arm-length fallbacks report zero surface confidence.
        // Remove those anchors before either projection or periodic segmentation can see them.
        for placement in anchors.placements where !LiveTrackingPolicy.supportedPlacement(placement) {
            anchors.remove(id: placement.id, session: controller.session)
        }
        if anchors.placements.isEmpty { invalidate(); return }
        tracker.start(keyframe: keyframe, placements: anchors.placements)
    }

    func projections(viewport: CGSize, scale: CGFloat, now: TimeInterval = CACurrentMediaTime()) -> [PartProjection] {
        guard running, !needsRecognition, let snapshot = controller.latest, let keyframe,
              LiveTrackingPolicy.sameView(reference: keyframe.snapshot.frame.camera.transform,
                                          current: snapshot.frame.camera.transform) else { return [] }
        let normal: Bool
        if case .normal = snapshot.frame.camera.trackingState { normal = true } else { normal = false }
        return LiveTrackingPolicy.visible(anchors.projections(frame: snapshot.frame, viewport: viewport, scale: scale),
                                          viewport: viewport, trackingNormal: normal, frameAge: now - snapshot.timestamp)
    }

    func status(visibleCount: Int) -> LiveCameraStatus {
        LiveCameraStatus.resolve(supported: controller.supported, permissionDenied: permissionDenied,
                                 needsRecognition: needsRecognition, waitingForKeyframe: waitingForKeyframe,
                                 phase: model.phase, visibleCount: visibleCount)
    }
}
