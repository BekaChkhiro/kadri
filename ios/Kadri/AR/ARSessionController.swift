@preconcurrency import ARKit
import Combine

@MainActor
final class ARSessionController: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()
    @Published private(set) var status = "ინიციალიზაცია"
    @Published private(set) var latest: FrameSnapshot?
    @Published private(set) var keyframe: Keyframe?
    @Published private(set) var captureStatus = ""
    private var frames: [FrameSnapshot] = []
    private let picker = KeyframePicker()
    private var capturing = false
    private var running = false
    // ARKit has a small pool of camera/depth buffers; retaining many ARFrames stalls frame delivery
    // (tracking stuck at initializing) and with LiDAR depth can crash. Keep one sample per 0.1 s,
    // five samples = 0.4 s, enough for KeyframePicker's 0.3 s stability window.
    let capacity = 5
    let sampleInterval: TimeInterval = 0.1
    var supported: Bool { ARWorldTrackingConfiguration.isSupported }

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = .main
    }

    func start() {
        guard supported else { status = "AR მიუწვდომელია"; return }
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) { configuration.frameSemantics.insert(.sceneDepth) }
        configuration.environmentTexturing = .none
        running = true
        session.run(configuration)
        // RealityKit's ARView owns session.delegate once it renders this session, so delegate
        // callbacks are not reliable here. Poll currentFrame on every screen refresh instead.
        displayLink?.invalidate()
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func pause() {
        running = false; displayLink?.invalidate(); displayLink = nil
        session.pause(); frames.removeAll(); latest = nil
    }

    private var displayLink: CADisplayLink?

    @objc private func tick() {
        guard running, let frame = session.currentFrame else { return }
        ingest(frame)
    }

    func capture() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }
        do {
            var candidates = frames
            if let latest, latest.timestamp > (candidates.last?.timestamp ?? 0) { candidates.append(latest) }
            let selected = try await picker.pick(candidates)
            guard running else { return }
            keyframe = selected
            captureStatus = String(format: "სიმკვეთრე: %.1f", selected.sharpness)
        } catch KeyframePicker.Failure.blurry(let score) {
            captureStatus = String(format: "ბუნდოვანი კადრი: %.1f — გააჩერეთ კამერა", score)
        } catch { captureStatus = "გააჩერეთ კამერა 300 მწ-ით და დაელოდეთ ნორმალურ ტრეკინგს" }
    }

    /// Transient selection only: detach pixels/geometry before inference and keep no extra ARFrame.
    func captureTouch(viewport: CGSize) async throws -> TouchFrame {
        guard running, !capturing else { throw KeyframePicker.Failure.unstable }
        capturing = true
        defer { capturing = false }
        var candidates = frames
        if let latest, latest.timestamp > (candidates.last?.timestamp ?? 0) { candidates.append(latest) }
        let selected = try await picker.pick(candidates, allowBlurry: true)
        guard running, case .normal = latest?.frame.camera.trackingState else { throw KeyframePicker.Failure.unstable }
        return TouchFrame(jpegData: selected.jpegData, reference: PartReference(keyframe: selected),
                          timestamp: selected.timestamp,
                          displayTransform: selected.snapshot.frame.displayTransform(for: .portrait, viewportSize: viewport))
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor [weak self] in self?.ingest(frame) }
    }

    private func ingest(_ frame: ARFrame) {
        guard running, frame.timestamp != latest?.timestamp else { return }
        let snapshot = FrameSnapshot(frame: frame)
        latest = snapshot
        if let last = frames.last, snapshot.timestamp - last.timestamp < sampleInterval {
            // Not yet time for a new sample; `latest` is appended at capture time.
        } else {
            frames.append(snapshot)
            if frames.count > capacity { frames.removeFirst(frames.count - capacity) }
        }
        let newStatus: String
        switch frame.camera.trackingState {
        case .normal: newStatus = "ტრეკინგი ნორმალურია"
        case .notAvailable: newStatus = "ტრეკინგი მიუწვდომელია"
        case .limited(let reason):
            switch reason {
            case .initializing: newStatus = "ინიციალიზაცია"
            case .excessiveMotion: newStatus = "შეზღუდული: შეანელეთ მოძრაობა"
            case .insufficientFeatures: newStatus = "შეზღუდული: მიუშვირეთ ტექსტურიან ზედაპირს"
            case .relocalizing: newStatus = "შეზღუდული: მდებარეობის აღდგენა"
            @unknown default: newStatus = "ტრეკინგი შეზღუდულია"
            }
        }
        if status != newStatus { status = newStatus }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in self?.invalidate("სესია შეჩერებულია") }
    }
    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in self?.invalidate("AR სესიის შეცდომა") }
    }
    private func invalidate(_ message: String) {
        frames.removeAll(); latest = nil; keyframe = nil; status = message
    }
}
