import Foundation
import Observation

/// Drives one guidance session: describing → scanning → parts → steps → done, with `error` reachable from
/// the network stages. All work runs in tasks owned by the model; a stale task (cancelled, timed out or
/// superseded by a retry) can never change `phase`, because every task carries the generation it was started in.
@MainActor
@Observable
public final class SessionModel {
    public private(set) var phase: SessionPhase = .idle
    /// Index into the steps of `.steps`; clamped to the steps received so far.
    public private(set) var currentStepIndex = 0
    /// The trimmed text sent with the last `submit`.
    public private(set) var instructions = ""
    /// Kept across `.error(_, retryFrom: .steps)` so a retry does not scan again.
    public private(set) var partsResult: PartsResult?
    /// Set by the server's done event.
    public private(set) var usage: StepsUsage?

    public let scanTimeout: Duration
    public let firstStepTimeout: Duration

    @ObservationIgnored private let api: any KadriAPI
    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var keyframeProvider: (@Sendable () async throws -> Data)?
    @ObservationIgnored private var receivedSteps: [Step] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored var workTask: Task<Void, Never>?
    @ObservationIgnored var timeoutTask: Task<Void, Never>?

    public init(
        api: any KadriAPI,
        clock: any Clock<Duration> = ContinuousClock(),
        scanTimeout: Duration = .seconds(45),
        firstStepTimeout: Duration = .seconds(60)
    ) {
        self.api = api
        self.clock = clock
        self.scanTimeout = scanTimeout
        self.firstStepTimeout = firstStepTimeout
    }

    /// The step at `currentStepIndex`, if any.
    public var currentStep: Step? {
        guard case .steps(_, let steps, _) = phase, steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    // MARK: - Describing

    /// Starts a new session from any phase, dropping whatever was in flight.
    public func beginDescribing() {
        stopWork()
        resetSession()
        phase = .describing(text: "")
    }

    public func updateText(_ text: String) {
        guard case .describing = phase else { return }
        phase = .describing(text: text)
    }

    // MARK: - Scanning

    /// Sends the current text with a keyframe. Ignored unless describing with non-empty text.
    /// The provider is kept so `retry()` from `.scan` captures a fresh keyframe.
    public func submit(keyframeProvider: @escaping @Sendable () async throws -> Data) {
        guard case .describing(let text) = phase else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        instructions = trimmed
        self.keyframeProvider = keyframeProvider
        startScan()
    }

    private func startScan() {
        guard let provider = keyframeProvider else { return }
        let gen = beginWork()
        partsResult = nil
        phase = .scanning(startedAt: Date())
        let instructions = instructions
        workTask = Task { [weak self, api] in
            do {
                let keyframe = try await provider()
                try Task.checkCancellation()
                let result = try await api.parts(keyframe: keyframe, instructions: instructions)
                self?.scanFinished(result, generation: gen)
            } catch {
                self?.fail(error, retryFrom: .scan, generation: gen)
            }
        }
        startTimeout(scanTimeout, retryFrom: .scan, generation: gen)
    }

    private func scanFinished(_ result: PartsResult, generation gen: Int) {
        guard gen == generation else { return }
        finishWork()
        guard !result.parts.isEmpty else {
            phase = .error(.noParts, retryFrom: .scan)
            return
        }
        partsResult = result
        phase = .parts(result)
    }

    // MARK: - Steps

    /// Requests steps for the parts. The phase becomes `.steps(parts, [], streaming: true)` at once and
    /// grows by one step per event, so the first step shows while the rest are still being written.
    public func startSteps() {
        guard case .parts(let result) = phase else { return }
        streamSteps(for: result)
    }

    private func streamSteps(for result: PartsResult) {
        let gen = beginWork()
        receivedSteps = []
        currentStepIndex = 0
        usage = nil
        phase = .steps(result, [], streaming: true)
        let instructions = instructions
        workTask = Task { [weak self, api] in
            let stream = api.steps(object: result.object, parts: result.parts, instructions: instructions)
            do {
                for try await event in stream {
                    guard let self, self.handle(event, result: result, generation: gen) else { return }
                }
                self?.streamEnded(result: result, generation: gen)
            } catch {
                self?.fail(error, retryFrom: .steps, generation: gen)
            }
        }
        startTimeout(firstStepTimeout, retryFrom: .steps, generation: gen)
    }

    /// Returns false once the stream should no longer be read.
    private func handle(_ event: StepEvent, result: PartsResult, generation gen: Int) -> Bool {
        guard gen == generation else { return false }
        switch event {
        case .step(let step):
            timeoutTask?.cancel()
            timeoutTask = nil
            receivedSteps.append(step)
            phase = .steps(result, receivedSteps, streaming: true)
            return true
        case .done(let usage):
            self.usage = usage
            streamEnded(result: result, generation: gen)
            return false
        }
    }

    /// The stream finished, with or without a done event.
    private func streamEnded(result: PartsResult, generation gen: Int) {
        guard gen == generation else { return }
        finishWork()
        guard !receivedSteps.isEmpty else {
            phase = .error(.server(code: "no_steps", message: "ინსტრუქცია ვერ შედგა. სცადეთ თავიდან."), retryFrom: .steps)
            return
        }
        phase = .steps(result, receivedSteps, streaming: false)
    }

    // MARK: - Navigation

    public func next() {
        guard case .steps(_, let steps, _) = phase, currentStepIndex < steps.count - 1 else { return }
        currentStepIndex += 1
    }

    public func previous() {
        guard case .steps = phase, currentStepIndex > 0 else { return }
        currentStepIndex -= 1
    }

    /// Ends the session once every step has arrived.
    public func finish() {
        guard case .steps(let result, let steps, streaming: false) = phase else { return }
        phase = .done(result, steps)
    }

    // MARK: - Retry and cancel

    /// From `.error`: `.scan` captures a new keyframe and asks for parts again; `.steps` keeps the parts.
    public func retry() {
        guard case .error(_, let point) = phase else { return }
        if point == .steps, let partsResult {
            streamSteps(for: partsResult)
        } else {
            startScan()
        }
    }

    /// Stops in-flight work. Scanning goes back to describing (text kept), streaming steps back to
    /// parts (parts kept); any other phase ends the session.
    public func cancel() {
        let previous = phase
        stopWork()
        switch previous {
        case .scanning:
            phase = .describing(text: instructions)
        case .steps(let result, _, streaming: true):
            receivedSteps = []
            currentStepIndex = 0
            phase = .parts(result)
        default:
            resetSession()
            phase = .idle
        }
    }

    // MARK: - Work bookkeeping

    /// Invalidates running work and returns the generation for the next task.
    private func beginWork() -> Int {
        stopWork()
        return generation
    }

    private func stopWork() {
        generation += 1
        workTask?.cancel()
        timeoutTask?.cancel()
        workTask = nil
        timeoutTask = nil
    }

    /// Current work completed on its own; nothing left to cancel.
    private func finishWork() {
        timeoutTask?.cancel()
        workTask = nil
        timeoutTask = nil
    }

    private func resetSession() {
        instructions = ""
        keyframeProvider = nil
        partsResult = nil
        receivedSteps = []
        currentStepIndex = 0
        usage = nil
    }

    private func startTimeout(_ duration: Duration, retryFrom point: RetryPoint, generation gen: Int) {
        timeoutTask = Task { [weak self, clock] in
            do {
                try await clock.sleep(for: duration)
            } catch {
                return
            }
            self?.timedOut(retryFrom: point, generation: gen)
        }
    }

    private func timedOut(retryFrom point: RetryPoint, generation gen: Int) {
        guard gen == generation else { return }
        timeoutTask = nil
        stopWork()
        phase = .error(.timeout, retryFrom: point)
    }

    private func fail(_ error: any Error, retryFrom point: RetryPoint, generation gen: Int) {
        guard gen == generation else { return }
        finishWork()
        phase = .error(SessionError(error), retryFrom: point)
    }
}
