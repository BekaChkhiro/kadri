import SwiftUI
import ARKit
import AVFoundation
import KadriCore
import os

private let liveLog = Logger(subsystem: "ge.kadri", category: "live-camera")

@MainActor
final class LiveCameraSession: ObservableObject {
    let controller = ARSessionController()
    let anchors = PartAnchors()
    let tracker = LiveContourTracker()
    let model: SessionModel
    @Published private(set) var needsRecognition = false
    @Published private(set) var permissionDenied = false
    @Published private(set) var waitingForKeyframe = true
    @Published private(set) var findingSurface = false
    @Published private(set) var recoveryReason: LiveRecoveryReason?
    @Published private(set) var placementReport = LivePlacementReport()
    @Published private(set) var diagnosticLine = "parts 0 · placed 0 · reason waiting"
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
    private var placementRetry = LivePlacementRetry()
    private var diagnosticReason = "waiting"
    private var lastTelemetryAt: TimeInterval = 0
    private var viewport: CGSize = .zero
    private var displayScale: CGFloat = 1
    // Sampled by telemetry at 1 Hz; never publish a SwiftUI change per frame.
    var overlayFPS: Double = 0
    var overlayVisibleCount = 0
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
        if started { needsRecognition = true; waitingForKeyframe = false; recoveryReason = .paused }
        started = true
        controller.start()
        // The consumer flow needs real raycast surfaces on non-LiDAR devices;
        // it deliberately cannot use PartAnchors' debug depth guesses.
        if let configuration = controller.session.configuration as? ARWorldTrackingConfiguration {
            configuration.planeDetection = [.horizontal, .vertical]
            controller.session.run(configuration)
        }
        recordTelemetry(force: true)
    }

    func stop() {
        running = false
        invalidate(.paused)
        controller.pause()
    }

    func recognizeAgain() {
        guard running else { return }
        clearRecognition()
        needsRecognition = false; waitingForKeyframe = true
        lastCaptureAttempt = 0
    }

    private func clearRecognition(resetDiagnostics: Bool = true) {
        generation += 1
        captureTask?.cancel(); captureTask = nil
        model.beginDescribing()
        tracker.stop()
        anchors.clear(session: controller.session)
        keyframe = nil; preparedResult = nil; selectedID = nil; lastTrackedTimestamp = nil
        findingSurface = false; placementRetry = LivePlacementRetry()
        if resetDiagnostics {
            placementReport = LivePlacementReport(); recoveryReason = nil; diagnosticReason = "waiting"
        }
    }

    private func invalidate(_ reason: LiveRecoveryReason) {
        clearRecognition(resetDiagnostics: false)
        recoveryReason = reason; diagnosticReason = reason.rawValue
        needsRecognition = true; waitingForKeyframe = false
        recordTelemetry(force: true)
    }

    /// Called for each new AR frame, and on a timer to catch frozen frame delivery.
    func update(now: TimeInterval = CACurrentMediaTime()) {
        guard running else { return }
        guard let snapshot = controller.latest else {
            if keyframe != nil { invalidate(.missingFrame) }
            else { recordTelemetry(now: now) }
            return
        }
        let normal: Bool
        if case .normal = snapshot.frame.camera.trackingState { normal = true } else { normal = false }
        if let keyframe {
            guard normal else { invalidate(.trackingLost); return }
            guard now - snapshot.timestamp >= 0, now - snapshot.timestamp < 0.5 else {
                invalidate(.staleFrame); return
            }
            guard LiveTrackingPolicy.sameView(reference: keyframe.snapshot.frame.camera.transform,
                                              current: snapshot.frame.camera.transform) else {
                invalidate(.viewChanged); return
            }
            if findingSurface {
                if placementRetry.expired(now: now) {
                    findingSurface = false
                    diagnosticReason = anchors.placements.isEmpty ? "surface_unavailable" : "partial_surface"
                    recordTelemetry(now: now, force: true)
                } else if placementRetry.shouldAttempt(now: now) {
                    attemptPlacement(now: now)
                }
            }
            if lastTrackedTimestamp != snapshot.timestamp {
                lastTrackedTimestamp = snapshot.timestamp
                tracker.update(snapshot: snapshot, anchors: anchors)
            }
        }
        recordTelemetry(now: now)
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
        diagnosticReason = "recognizing"
        model.beginDescribing()
        let text = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        model.updateText(text.isEmpty ? "მაჩვენე ობიექტის ხილული ნაწილები და ამიხსენი მათი დანიშნულება." : text)
        let error = authError
        model.submit(provider: .gemini) {
            if let error { throw error }
            return jpeg
        }
        recordTelemetry(force: true)
    }

    func phaseChanged() {
        if case .error(let error, _) = model.phase {
            diagnosticReason = error == .noParts ? "no_parts" : "api_error"
            recordTelemetry(force: true)
            return
        }
        guard case .parts(let result) = model.phase, preparedResult != result, !needsRecognition else { return }
        preparedResult = result
        placementReport = .make(parts: result.parts, placements: [])
        guard keyframe != nil, running else { recordTelemetry(force: true); return }
        let now = CACurrentMediaTime()
        placementRetry.begin(now: now)
        findingSurface = true
        attemptPlacement(now: now)
    }

    private func attemptPlacement(now: TimeInterval) {
        guard let result = preparedResult, let keyframe, running, !needsRecognition,
              placementRetry.shouldAttempt(now: now) else { return }
        placementRetry.didAttempt(now: now)
        let previousIDs = Set(anchors.placements.map(\.id))
        let pending = result.parts.filter { !previousIDs.contains($0.id) }
        // An unsuccessful append retains its reference internally. Remove it before
        // retrying so PartAnchors does not treat the part as already processed.
        for part in pending { anchors.remove(id: part.id, session: controller.session) }
        anchors.append(reference: PartReference(keyframe: keyframe), parts: pending.map { ($0.id, $0.box) },
                       session: controller.session)
        placementReport = .make(parts: result.parts, placements: anchors.placements)
        // PartAnchors' debug-only feature/arm-length fallbacks report zero surface confidence.
        // Remove those anchors before either projection or periodic segmentation can see them.
        for placement in anchors.placements where !LiveTrackingPolicy.supportedPlacement(placement) {
            anchors.remove(id: placement.id, session: controller.session)
        }
        let currentIDs = Set(anchors.placements.map(\.id))
        findingSurface = result.parts.contains { $0.hasValidBox && !currentIDs.contains($0.id) }
        diagnosticReason = currentIDs.isEmpty ? (findingSurface ? "surface_waiting" : "invalid_boxes")
            : (findingSurface ? "partial_surface" : "bound")
        if currentIDs != previousIDs, !currentIDs.isEmpty {
            tracker.start(keyframe: keyframe, placements: anchors.placements)
        }
        // Keep the AI result even when nothing is anchored yet. Another local
        // raycast may succeed once ARKit has observed enough of the surface.
        recordTelemetry(now: now, force: true)
    }

    func projections(viewport: CGSize, scale: CGFloat, now: TimeInterval = CACurrentMediaTime()) -> [PartProjection] {
        guard let frame = controller.session.currentFrame else { return [] }
        return projections(frame: frame, viewport: viewport, scale: scale, now: now)
    }

    func projections(frame: ARFrame, viewport: CGSize, scale: CGFloat, now: TimeInterval) -> [PartProjection] {
        let snapshot = FrameSnapshot(frame: frame)
        guard running, !needsRecognition, let keyframe,
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
                                 phase: model.phase, visibleCount: visibleCount, recovery: recoveryReason,
                                 findingSurface: findingSurface, placedCount: anchors.placements.count)
    }

    func setViewport(_ size: CGSize, scale: CGFloat) {
        viewport = size; displayScale = scale
    }

    private func recordTelemetry(now: TimeInterval = CACurrentMediaTime(), force: Bool = false) {
        guard force || now - lastTelemetryAt >= 1 else { return }
        lastTelemetryAt = now
        let frame = controller.latest?.frame
        let tracking: String
        switch frame?.camera.trackingState {
        case .normal: tracking = "normal"
        case .notAvailable: tracking = "unavailable"
        case .limited(.initializing): tracking = "initializing"
        case .limited(.excessiveMotion): tracking = "motion"
        case .limited(.insufficientFeatures): tracking = "features"
        case .limited(.relocalizing): tracking = "relocalizing"
        default: tracking = "unknown"
        }
        let report = placementReport
        let visible = projections(viewport: viewport, scale: displayScale, now: now).count
        let planes = frame?.anchors.filter { $0 is ARPlaneAnchor }.count ?? 0
        let planeMode = (controller.session.configuration as? ARWorldTrackingConfiguration)?.planeDetection.rawValue ?? 0
        let age = frame.map { Int(max(0, now - $0.timestamp) * 1000) } ?? -1
        let line = "parts \(report.parts) · placed \(anchors.placements.count) · visible \(visible)"
            + " · noDepth \(report.noDepth) · weakDepth \(report.weakDepth)"
            + " · invalidBox \(report.invalidBox) · noPlacement \(report.noPlacement)"
            + " · reason \(diagnosticReason) · tracking \(tracking)"
            + " · planes \(planes)/\(planeMode) · ageMs \(age) · bindTry \(placementRetry.attempts)"
            + " · refreshOK \(tracker.refreshAccepted) · refreshReject \(tracker.refreshRejected)"
            + " · overlayFPS \(Int(overlayFPS.rounded())) · refreshAgeMs \(tracker.refreshAgeMilliseconds(now: now))"
        diagnosticLine = line
        // Counts and fixed reason codes only: no image, token, user text or part labels.
        liveLog.notice("LIVE_CAMERA \(line, privacy: .public)")
    }
}
