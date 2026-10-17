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
    let capacity = 24 // ~400 ms at 60 fps; bounds retained camera/depth buffers.
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
    }

    func pause() { running = false; session.pause(); frames.removeAll(); latest = nil }

    func capture() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }
        do {
            let selected = try await picker.pick(frames)
            guard running else { return }
            keyframe = selected
            captureStatus = String(format: "სიმკვეთრე: %.1f", selected.sharpness)
        } catch KeyframePicker.Failure.blurry(let score) {
            captureStatus = String(format: "ბუნდოვანი კადრი: %.1f — გააჩერეთ კამერა", score)
        } catch { captureStatus = "გააჩერეთ კამერა 300 მწ-ით და დაელოდეთ ნორმალურ ტრეკინგს" }
    }

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let snapshot = FrameSnapshot(frame: frame)
        Task { @MainActor [weak self] in
            guard let self, self.running else { return }
            self.latest = snapshot
            self.frames.append(snapshot)
            if self.frames.count > self.capacity { self.frames.removeFirst(self.frames.count - self.capacity) }
            switch frame.camera.trackingState {
            case .normal: self.status = "ტრეკინგი ნორმალურია"
            case .notAvailable: self.status = "ტრეკინგი მიუწვდომელია"
            case .limited(let reason):
                switch reason {
                case .initializing: self.status = "ინიციალიზაცია"
                case .excessiveMotion: self.status = "შეზღუდული: შეანელეთ მოძრაობა"
                case .insufficientFeatures: self.status = "შეზღუდული: მიუშვირეთ ტექსტურიან ზედაპირს"
                case .relocalizing: self.status = "შეზღუდული: მდებარეობის აღდგენა"
                @unknown default: self.status = "ტრეკინგი შეზღუდულია"
                }
            }
        }
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
