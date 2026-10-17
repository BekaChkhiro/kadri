import Foundation
import Observation

/// Drives one guidance session: describing → scanning → parts → steps → done, with `error` reachable from
/// the network stages. All work runs in tasks owned by the model; a stale task (cancelled, timed out or
/// superseded by a retry) can never change `phase`, because every task carries the generation it was started in.
///
/// A session can span several photos (rounds). When a round's steps end with `.needsPhoto`,
/// `continueWithPhoto(keyframeProvider:)` files the round in `completedRounds` and scans again with a
/// `SessionContext`; `phase` always describes the current round, while step navigation runs over `allSteps`.
@MainActor
@Observable
public final class SessionModel {
    public static let maxRounds = 5

    public private(set) var phase: SessionPhase = .idle
    /// Index into `allSteps`; clamped to the steps received so far.
    public private(set) var currentStepIndex = 0
    /// Finished rounds before the current one, oldest first.
    public private(set) var completedRounds: [SessionRound] = []
    /// The current round's continuation, set by the done event (nil while streaming).
    /// Always `.complete` in round `maxRounds`.
    public private(set) var continuation: StepsContinuation?
    /// The context sent with the current round's requests; nil in round 1.
    public private(set) var pendingContext: SessionContext?
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
        guard case .steps = phase else { return nil }
        let steps = allSteps
        return steps.indices.contains(currentStepIndex) ? steps[currentStepIndex] : nil
    }

    /// 1-based number of the current round.
    public var round: Int { completedRounds.count + 1 }

    /// How many steps the earlier rounds hold; the current round's first step has this global index.
    public var stepOffset: Int { completedRounds.reduce(0) { $0 + $1.steps.count } }

    /// Every step of the session: the earlier rounds' and then the current round's.
    public var allSteps: [Step] {
        completedRounds.flatMap(\.steps) + currentRoundSteps
    }

    /// The current round finished with a request for another photo, and another round is allowed.
    public var canContinueWithPhoto: Bool {
        guard case .steps(_, _, streaming: false) = phase, case .needsPhoto = continuation else { return false }
        return round < Self.maxRounds
    }

    /// The round `currentStepIndex` belongs to; it trails `round` after `previous()` crosses into an earlier round.
    public var displayedRound: Int {
        var end = 0
        for done in completedRounds {
            end += done.steps.count
            if currentStepIndex < end { return done.number }
        }
        return round
    }

    /// The parts of `displayedRound`.
    public var displayedResult: PartsResult? {
        let number = displayedRound
        return number == round ? partsResult : completedRounds.first { $0.number == number }?.result
    }

    private var currentRoundSteps: [Step] {
        switch phase {
        case .steps(_, let steps, _), .done(_, let steps): return steps
        default: return []
        }
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
        let context = pendingContext
        workTask = Task { [weak self, api] in
            do {
                let keyframe = try await provider()
                try Task.checkCancellation()
                let result = try await api.parts(keyframe: keyframe, instructions: instructions, context: context)
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
        currentStepIndex = stepOffset
        usage = nil
        continuation = nil
        phase = .steps(result, [], streaming: true)
        let instructions = instructions
        let context = pendingContext
        workTask = Task { [weak self, api] in
            let stream = api.steps(object: result.object, parts: result.parts, instructions: instructions, context: context)
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
        case .done(let usage, let continuation):
            self.usage = usage
            self.continuation = continuation
            streamEnded(result: result, generation: gen)
            return false
        }
    }

    /// The stream finished, with or without a done event.
    private func streamEnded(result: PartsResult, generation gen: Int) {
        guard gen == generation else { return }
        finishWork()
        guard !receivedSteps.isEmpty else {
            continuation = nil
            phase = .error(.server(code: "no_steps", message: "ინსტრუქცია ვერ შედგა. სცადეთ თავიდან."), retryFrom: .steps)
            return
        }
        // A stream without a done event (or the last allowed round) cannot ask for another photo.
        if continuation == nil || round >= Self.maxRounds { continuation = .complete }
        phase = .steps(result, receivedSteps, streaming: false)
    }

    // MARK: - More photos

    /// Files the current round and scans a new photo for the next one, sending a `SessionContext`
    /// built from the `.needsPhoto` prompt and every step so far. Ignored unless `canContinueWithPhoto`.
    /// After the scan the flow is the same as for the first photo: `.parts`, then `startSteps()`.
    public func continueWithPhoto(keyframeProvider: @escaping @Sendable () async throws -> Data) {
        guard canContinueWithPhoto, case .steps(let result, let steps, _) = phase,
              let continuation else { return }
        completedRounds.append(SessionRound(number: round, photoPrompt: pendingContext?.photoPrompt,
                                            result: result, steps: steps, continuation: continuation))
        pendingContext = context(forRound: round)
        self.continuation = nil
        usage = nil
        receivedSteps = []
        currentStepIndex = stepOffset
        self.keyframeProvider = keyframeProvider
        startScan()
    }

    /// The context round `number` (≥ 2) is requested with, derived from the rounds before it.
    private func context(forRound number: Int) -> SessionContext? {
        guard number >= 2, completedRounds.count >= number - 1 else { return nil }
        let earlier = completedRounds.prefix(number - 1)
        guard let last = earlier.last, case .needsPhoto(let prompt, _) = last.continuation else { return nil }
        return SessionContext(round: number, photoPrompt: prompt, doneSteps: earlier.flatMap(\.steps).map(\.title),
                              previousObject: last.result.object)
    }

    /// Makes the last finished round current again, as it was when its steps ended.
    private func restorePreviousRound() {
        guard let last = completedRounds.popLast() else { return }
        pendingContext = context(forRound: round)
        partsResult = last.result
        receivedSteps = last.steps
        continuation = last.continuation
        usage = nil
        phase = .steps(last.result, last.steps, streaming: false)
        currentStepIndex = max(stepOffset, allSteps.count - 1)
    }

    // MARK: - Navigation

    /// Moves through `allSteps`, so it can cross from an earlier round into the current one.
    public func next() {
        guard case .steps = phase, currentStepIndex < allSteps.count - 1 else { return }
        currentStepIndex += 1
    }

    /// Can cross back into an earlier round (`displayedRound` follows).
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
    /// parts (parts kept); any other phase ends the session. From round 2 on, cancelling the new photo
    /// (scanning, parts or an error) returns to the previous round's finished steps instead.
    public func cancel() {
        let previous = phase
        stopWork()
        switch previous {
        case .scanning where round > 1, .parts where round > 1, .error where round > 1:
            restorePreviousRound()
        case .scanning:
            phase = .describing(text: instructions)
        case .steps(let result, _, streaming: true):
            receivedSteps = []
            currentStepIndex = stepOffset
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
        completedRounds = []
        continuation = nil
        pendingContext = nil
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
        #if DEBUG
        print("[Kadri] session failed at \(point): \(String(reflecting: error))")
        #endif
        phase = .error(SessionError(error), retryFrom: point)
    }
}
