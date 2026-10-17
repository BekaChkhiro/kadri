import Foundation
import XCTest
@testable import KadriCore

@MainActor
final class SessionModelTests: XCTestCase {
    private var api: MockKadriAPI!
    private var clock: TestClock!
    private var model: SessionModel!

    override func setUp() async throws {
        api = MockKadriAPI(parts: .success(Fixtures.parts))
        clock = TestClock()
        model = SessionModel(api: api, clock: clock)
    }

    private func submit(_ text: String = "როგორ შევცვალო ონკანის ქანჩი?") {
        model.beginDescribing()
        model.updateText(text)
        model.submit { Fixtures.keyframe }
    }

    private func reachParts() async {
        submit()
        await model.workTask?.value
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
    }

    private func isError(_ point: RetryPoint) -> Bool {
        if case .error(_, point) = model.phase { return true }
        return false
    }

    private var answerRequest: StepsContinuation {
        .needsAnswer(question: "ტრიალებს?", options: ["კი", "არა"], allowOther: true, reason: nil)
    }

    private func finishTurn(_ call: Int, steps: [Step] = Fixtures.steps, continuation: StepsContinuation) async {
        await waitUntil { self.api.stepsCalls.count > call }
        let stream = api.stepsContinuation(call)
        steps.forEach { stream.yield(.step($0)) }
        stream.yield(.done(nil, continuation: continuation))
        await model.workTask?.value
    }

    func testGeminiStaysSelectedAcrossAnswersPhotosAndRetry() async {
        model.beginDescribing()
        model.updateText("ჟონავს")
        model.submit(provider: .gemini) { Fixtures.keyframe }
        await model.workTask?.value
        model.startSteps()
        await finishTurn(0, continuation: answerRequest)
        model.continueWithAnswer("კი")
        await finishTurn(1, continuation: .needsPhoto(prompt: "ახლოდან", reason: "შიგნით"))
        model.continueWithPhoto { Fixtures.keyframe }
        await model.workTask?.value
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 3 }
        api.stepsContinuation(2).finish(throwing: SessionError.timeout)
        await model.workTask?.value
        model.retry()
        await finishTurn(3, continuation: .complete)
        XCTAssertEqual(model.aiProvider, .gemini)
        XCTAssertEqual(api.partsCalls.map(\.provider), [.gemini, .gemini])
        XCTAssertEqual(api.stepsCalls.map(\.provider), [.gemini, .gemini, .gemini, .gemini])
        model.beginDescribing()
        model.updateText("ახალი")
        model.submit { Fixtures.keyframe }
        await model.workTask?.value
        XCTAssertEqual(model.aiProvider, .astra)
        XCTAssertNil(api.partsCalls.last?.provider)
    }

    func testAnswerAndMeasurementKeepPhotoAndGlobalNavigation() async {
        await reachParts()
        model.startSteps()
        await finishTurn(0, continuation: answerRequest)
        model.continueWithAnswer("კი")
        XCTAssertEqual(model.stepOffset, 3)
        XCTAssertEqual(model.round, 1)
        let measurement = StepsContinuation.needsMeasurement(question: "რამდენი?", unit: "mA", min: 0, max: 500, how: "გაზომე", reason: nil)
        await finishTurn(1, steps: Array(Fixtures.steps.prefix(2)), continuation: measurement)
        XCTAssertEqual(model.allSteps.count, 5)
        XCTAssertEqual(api.stepsCalls[1].context?.answers, [SessionAnswer(question: "ტრიალებს?", answer: "კი")])
        XCTAssertEqual(api.stepsCalls[1].context?.doneSteps, Fixtures.steps.map(\.title))
        XCTAssertEqual(api.stepsCalls[1].object, api.stepsCalls[0].object)
        model.previous()
        XCTAssertEqual(model.currentStepIndex, 2)
        XCTAssertEqual(model.displayedRound, 1)
        XCTAssertEqual(model.displayedResult, Fixtures.parts)
        model.continueWithAnswer("30", unit: "mA")
        await finishTurn(2, steps: Array(Fixtures.steps.prefix(2)), continuation: .complete(cause: "მიზეზი", summary: "შეჯამება"))
        XCTAssertEqual(model.allSteps.count, 7)
        XCTAssertEqual(model.stepOffset, 5)
        XCTAssertEqual(model.answers.last?.unit, "mA")
        XCTAssertEqual(model.foundCause, "მიზეზი")
        XCTAssertEqual(model.completionSummary, "შეჯამება")
        XCTAssertEqual(api.partsCalls.count, 1)
        model.finish()
        XCTAssertEqual(model.allSteps.count, 7)
    }

    func testAnswerThenPhotoWaitKeepsStepsAndContinuesTheNextRound() async {
        model = SessionModel(api: api, clock: clock, scanTimeout: .seconds(20), firstStepTimeout: .seconds(20))
        await reachParts()
        model.startSteps()
        await finishTurn(0, continuation: answerRequest)
        model.continueWithAnswer("კი")
        let next = StepsContinuation.needsPhoto(prompt: "ახლოდან", reason: "შუასადები არ ჩანს")
        await finishTurn(1, steps: Array(Fixtures.steps.prefix(2)), continuation: next)
        model.next()
        let phase = model.phase
        clock.advance(by: .seconds(30))
        await waitUntil { self.clock.sleeperCount == 0 }
        await Task.yield()
        XCTAssertEqual(model.phase, phase)
        XCTAssertTrue(model.canContinueWithPhoto)
        XCTAssertEqual(model.allSteps.count, 5)
        XCTAssertEqual(model.currentStepIndex, 4)
        XCTAssertEqual(model.displayedRound, 1)
        XCTAssertEqual(model.stepOffset, 3)
        XCTAssertNil(model.timeoutTask)

        model.continueWithPhoto { Fixtures.keyframe }
        await model.workTask?.value
        model.startSteps()
        await finishTurn(2, continuation: .complete)
        XCTAssertEqual(model.round, 2)
        XCTAssertEqual(model.allSteps.count, 8)
        XCTAssertEqual(model.stepOffset, 5)
        XCTAssertEqual(model.currentStepIndex, 5)
        XCTAssertEqual(model.displayedRound, 2)
        XCTAssertEqual(model.pendingContext?.answers.count, 1)
        model.previous()
        XCTAssertEqual(model.displayedRound, 1)
        XCTAssertEqual(model.currentStepIndex, 4)
    }

    func testAnswerTurnLimit() async {
        await reachParts()
        model.startSteps()
        await finishTurn(0, continuation: answerRequest)
        for call in 1...6 {
            XCTAssertTrue(model.canContinueWithAnswer)
            model.continueWithAnswer("კი")
            await finishTurn(call, continuation: answerRequest)
        }
        XCTAssertFalse(model.canContinueWithAnswer)
        XCTAssertEqual(model.answers.count, 6)
        XCTAssertTrue(model.continuation?.isComplete == true)
        model.continueWithAnswer("კი")
        XCTAssertEqual(api.stepsCalls.count, 7)
    }

    func testAnswerRetryAndCancelRestorePreviousTurn() async {
        await reachParts()
        model.startSteps()
        await finishTurn(0, continuation: answerRequest)
        model.continueWithAnswer("არა")
        await waitUntil { self.api.stepsCalls.count == 2 }
        let context = model.pendingContext
        api.stepsContinuation(1).finish(throwing: SessionError.network)
        await model.workTask?.value
        model.retry()
        await waitUntil { self.api.stepsCalls.count == 3 }
        XCTAssertEqual(api.stepsCalls[2].context, context)
        model.cancel()
        XCTAssertEqual(model.allSteps, Fixtures.steps)
        XCTAssertTrue(model.canContinueWithAnswer)
        XCTAssertTrue(model.answers.isEmpty)
        XCTAssertNil(model.pendingContext)
        XCTAssertEqual(model.stepOffset, 0)
        model.continueWithAnswer("კი")
        await waitUntil { self.api.stepsCalls.count == 4 }
        api.stepsContinuation(3).finish(throwing: SessionError.network)
        await model.workTask?.value
        model.cancel()
        XCTAssertTrue(model.canContinueWithAnswer)
        XCTAssertEqual(model.round, 1)
    }

    func testPhotoThenAnswerKeepsRoundTwoAndCarriesAnswersForward() async {
        await reachParts()
        model.startSteps()
        await finishTurn(0, continuation: .needsPhoto(prompt: "ახლოდან", reason: "მიზეზი"))
        model.continueWithPhoto { Fixtures.keyframe }
        await model.workTask?.value
        model.startSteps()
        await finishTurn(1, continuation: answerRequest)
        model.continueWithAnswer("კი")
        await finishTurn(2, continuation: .needsPhoto(prompt: "გვერდიდან", reason: "მიზეზი"))
        XCTAssertEqual(model.round, 2)
        XCTAssertEqual(api.stepsCalls[2].context?.photoPrompt, "ახლოდან")
        XCTAssertEqual(api.stepsCalls[2].context?.answers.count, 1)
        model.previous()
        XCTAssertEqual(model.displayedRound, 2)
        model.continueWithPhoto { Fixtures.keyframe }
        XCTAssertEqual(model.round, 3)
        XCTAssertEqual(model.pendingContext?.answers.count, 1)
        model.cancel()
        XCTAssertEqual(model.round, 2)
        XCTAssertEqual(model.allSteps.count, 9)
        XCTAssertEqual(model.stepOffset, 6)
        XCTAssertEqual(model.answers.count, 1)
    }

    // MARK: - Happy path

    func testFullFlowIdleToDone() async {
        XCTAssertEqual(model.phase, .idle)
        model.beginDescribing()
        XCTAssertEqual(model.phase, .describing(text: ""))
        model.updateText("  როგორ შევცვალო ქანჩი?  ")
        XCTAssertEqual(model.phase, .describing(text: "  როგორ შევცვალო ქანჩი?  "))

        model.submit { Fixtures.keyframe }
        guard case .scanning = model.phase else { return XCTFail("expected scanning, got \(model.phase)") }
        await model.workTask?.value
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
        XCTAssertEqual(api.partsCalls.count, 1)
        XCTAssertEqual(api.partsCalls.first?.keyframe, Fixtures.keyframe)
        XCTAssertEqual(api.partsCalls.first?.instructions, "როგორ შევცვალო ქანჩი?")

        model.startSteps()
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [], streaming: true))
        await waitUntil { self.api.stepsCalls.count == 1 }
        XCTAssertEqual(
            api.stepsCalls.first,
            .init(object: "ონკანი", parts: Fixtures.parts.parts, instructions: "როგორ შევცვალო ქანჩი?")
        )

        let stream = api.stepsContinuation(0)
        for (i, step) in Fixtures.steps.enumerated() {
            stream.yield(.step(step))
            await waitUntil { self.model.phase == .steps(Fixtures.parts, Array(Fixtures.steps[...i]), streaming: true) }
        }
        let usage = StepsUsage(inputTokens: 1200, outputTokens: 800, costUsd: 0.012)
        stream.yield(.done(usage))
        await model.workTask?.value
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, Fixtures.steps, streaming: false))
        XCTAssertEqual(model.usage, usage)

        model.finish()
        XCTAssertEqual(model.phase, .done(Fixtures.parts, Fixtures.steps))
    }

    func testFirstStepEventShowsOneStepWhileStreaming() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        api.stepsContinuation(0).yield(.step(Fixtures.steps[0]))
        await waitUntil { self.model.currentStep != nil }
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [Fixtures.steps[0]], streaming: true))
        XCTAssertEqual(model.currentStep, Fixtures.steps[0])
        model.finish()
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [Fixtures.steps[0]], streaming: true), "finish waits for all steps")
    }

    func testDoneEventEndsStreaming() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        let stream = api.stepsContinuation(0)
        stream.yield(.step(Fixtures.steps[0]))
        stream.yield(.done(nil))
        await model.workTask?.value
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [Fixtures.steps[0]], streaming: false))
        XCTAssertNil(model.usage)
    }

    func testStreamEndingWithoutDoneEventEndsStreaming() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        let stream = api.stepsContinuation(0)
        stream.yield(.step(Fixtures.steps[0]))
        stream.finish()
        await model.workTask?.value
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [Fixtures.steps[0]], streaming: false))
    }

    func testDoneWithoutStepsIsStepsError() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        api.stepsContinuation(0).yield(.done(nil))
        await model.workTask?.value
        XCTAssertTrue(isError(.steps), "got \(model.phase)")
    }

    // MARK: - Input guards

    func testSubmitIgnoresBlankText() {
        submit("   \n")
        XCTAssertEqual(model.phase, .describing(text: "   \n"))
        XCTAssertTrue(api.partsCalls.isEmpty)
    }

    func testUpdateTextOnlyWhileDescribing() {
        model.updateText("x")
        XCTAssertEqual(model.phase, .idle)
    }

    func testEmptyPartsIsNoPartsError() async {
        api.setParts(.success(PartsResult(object: "ონკანი", parts: [])))
        submit()
        await model.workTask?.value
        XCTAssertEqual(model.phase, .error(.noParts, retryFrom: .scan))
    }

    // MARK: - Errors and retry

    func testPartsNetworkErrorRetriesScan() async {
        api.setParts(.failure(URLError(.notConnectedToInternet)), .success(Fixtures.parts))
        let captures = Counter()
        model.beginDescribing()
        model.updateText("ქანჩი")
        model.submit { captures.increment(); return Fixtures.keyframe }
        await model.workTask?.value
        XCTAssertEqual(model.phase, .error(.network, retryFrom: .scan))
        XCTAssertNil(model.partsResult)

        model.retry()
        guard case .scanning = model.phase else { return XCTFail("expected scanning, got \(model.phase)") }
        await model.workTask?.value
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
        XCTAssertEqual(api.partsCalls.count, 2)
        XCTAssertEqual(captures.value, 2, "scan retry captures a fresh keyframe")
        XCTAssertEqual(api.partsCalls.last?.instructions, "ქანჩი")
    }

    func testKeyframeFailureIsScanError() async {
        model.beginDescribing()
        model.updateText("ქანჩი")
        model.submit { throw URLError(.cannotLoadFromNetwork) }
        await model.workTask?.value
        XCTAssertTrue(isError(.scan))
        XCTAssertTrue(api.partsCalls.isEmpty)
    }

    func testStepsErrorRetryKeepsParts() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        let first = api.stepsContinuation(0)
        first.yield(.step(Fixtures.steps[0]))
        first.finish(throwing: SessionError(status: 500, body: Data(#"{"error":{"code":"ai_error","message":"AI-მ ვერ უპასუხა"}}"#.utf8)))
        await model.workTask?.value
        XCTAssertEqual(model.phase, .error(.server(code: "ai_error", message: "AI-მ ვერ უპასუხა"), retryFrom: .steps))
        XCTAssertEqual(model.partsResult, Fixtures.parts)

        model.retry()
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [], streaming: true), "retry restarts the steps from scratch")
        await waitUntil { self.api.stepsCalls.count == 2 }
        XCTAssertEqual(api.partsCalls.count, 1, "steps retry does not scan again")
        let second = api.stepsContinuation(1)
        Fixtures.steps.forEach { second.yield(.step($0)) }
        second.yield(.done(nil))
        await model.workTask?.value
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, Fixtures.steps, streaming: false))
    }

    func testRetryOutsideErrorDoesNothing() async {
        await reachParts()
        model.retry()
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
        XCTAssertEqual(api.partsCalls.count, 1)
    }

    // MARK: - Cancel

    func testCancelWhileScanningReturnsToDescribing() async {
        api.setParts(.hang)
        submit("ქანჩი")
        await waitUntil { self.api.partsCalls.count == 1 }
        let task = model.workTask
        model.cancel()
        XCTAssertEqual(model.phase, .describing(text: "ქანჩი"))
        await task?.value
        XCTAssertEqual(model.phase, .describing(text: "ქანჩი"), "the cancelled request must not change the phase")
        XCTAssertNil(model.workTask)
        XCTAssertEqual(clock.sleeperCount, 0, "the scan timeout is cancelled too")
    }

    func testCancelWhileStreamingReturnsToPartsAndClosesStream() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        api.stepsContinuation(0).yield(.step(Fixtures.steps[0]))
        await waitUntil { self.model.currentStep != nil }
        model.cancel()
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
        await waitUntil("stream terminated") { self.api.terminatedStreams == 1 }
        api.stepsContinuation(0).yield(.step(Fixtures.steps[1]))
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
    }

    func testCancelKeepsFinishedAnswerTurnWaitingForPhoto() async {
        await assertCancelKeepsFinishedAnswerTurn(.needsPhoto(prompt: "ახლოდან", reason: "შუასადები არ ჩანს"))
        XCTAssertTrue(model.canContinueWithPhoto)
    }

    func testCancelKeepsFinishedAnswerTurnWaitingForAnswer() async {
        await assertCancelKeepsFinishedAnswerTurn(answerRequest)
        XCTAssertTrue(model.canContinueWithAnswer)
    }

    private func assertCancelKeepsFinishedAnswerTurn(_ continuation: StepsContinuation) async {
        await reachParts()
        model.startSteps()
        await finishTurn(0, continuation: answerRequest)
        model.continueWithAnswer("კი")
        await finishTurn(1, steps: Array(Fixtures.steps.prefix(2)), continuation: continuation)
        model.next()
        let phase = model.phase
        let steps = model.allSteps
        let turns = model.completedTurns
        let answers = model.answers
        let context = model.pendingContext
        let index = model.currentStepIndex

        model.cancel()

        XCTAssertEqual(model.phase, phase)
        XCTAssertEqual(model.allSteps, steps)
        XCTAssertEqual(model.completedTurns, turns)
        XCTAssertEqual(model.answers, answers)
        XCTAssertEqual(model.pendingContext, context)
        XCTAssertEqual(model.continuation, continuation)
        XCTAssertEqual(model.currentStepIndex, index)
        XCTAssertEqual(model.partsResult, Fixtures.parts)
        XCTAssertEqual(model.stepOffset, 3)
        XCTAssertEqual(model.round, 1)
    }

    func testCancelFromPartsEndsSession() async {
        await reachParts()
        model.cancel()
        XCTAssertEqual(model.phase, .idle)
        XCTAssertNil(model.partsResult)
        XCTAssertEqual(model.instructions, "")
    }

    func testBeginDescribingDropsInFlightScan() async {
        api.setParts(.hang)
        submit()
        await waitUntil { self.api.partsCalls.count == 1 }
        model.beginDescribing()
        XCTAssertEqual(model.phase, .describing(text: ""))
        XCTAssertNil(model.workTask)
    }

    // MARK: - Timeouts

    func testScanTimesOutAfter45Seconds() async {
        api.setParts(.hang)
        submit()
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: .seconds(44))
        try? await Task.sleep(for: .milliseconds(20))
        guard case .scanning = model.phase else { return XCTFail("timed out early: \(model.phase)") }

        let task = model.workTask
        clock.advance(by: .seconds(1))
        await waitUntil { self.model.phase == .error(.timeout, retryFrom: .scan) }
        await task?.value
        XCTAssertEqual(model.phase, .error(.timeout, retryFrom: .scan), "the cancelled request must not overwrite the timeout")
    }

    func testFirstStepTimesOutAfter60Seconds() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.clock.sleeperCount == 1 }
        clock.advance(by: .seconds(59))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [], streaming: true))

        clock.advance(by: .seconds(1))
        await waitUntil { self.model.phase == .error(.timeout, retryFrom: .steps) }
        await waitUntil("stream terminated") { self.api.terminatedStreams == 1 }
        XCTAssertEqual(model.partsResult, Fixtures.parts)
    }

    func testFirstStepCancelsStepsTimeout() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.clock.sleeperCount == 1 }
        api.stepsContinuation(0).yield(.step(Fixtures.steps[0]))
        await waitUntil { self.clock.sleeperCount == 0 }
        clock.advance(by: .seconds(120))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, [Fixtures.steps[0]], streaming: true))
    }

    func testFinishedScanCancelsTimeout() async {
        await reachParts()
        XCTAssertEqual(clock.sleeperCount, 0)
        clock.advance(by: .seconds(100))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(model.phase, .parts(Fixtures.parts))
    }

    // MARK: - Navigation

    func testNextAndPreviousStayInBounds() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        let stream = api.stepsContinuation(0)

        model.previous()
        model.next()
        XCTAssertEqual(model.currentStepIndex, 0, "no steps yet")

        stream.yield(.step(Fixtures.steps[0]))
        await waitUntil { self.model.currentStep != nil }
        model.next()
        XCTAssertEqual(model.currentStepIndex, 0, "next waits for the next step to arrive")

        stream.yield(.step(Fixtures.steps[1]))
        stream.yield(.step(Fixtures.steps[2]))
        stream.yield(.done(nil))
        await model.workTask?.value

        model.next()
        model.next()
        XCTAssertEqual(model.currentStep, Fixtures.steps[2])
        model.next()
        XCTAssertEqual(model.currentStepIndex, 2)
        model.previous()
        model.previous()
        model.previous()
        XCTAssertEqual(model.currentStepIndex, 0)
        XCTAssertEqual(model.currentStep, Fixtures.steps[0])
    }

    func testRetryOfStepsResetsStepIndex() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        let stream = api.stepsContinuation(0)
        stream.yield(.step(Fixtures.steps[0]))
        stream.yield(.step(Fixtures.steps[1]))
        await waitUntil { self.model.phase == .steps(Fixtures.parts, Array(Fixtures.steps[...1]), streaming: true) }
        model.next()
        XCTAssertEqual(model.currentStepIndex, 1)
        stream.finish(throwing: URLError(.networkConnectionLost))
        await model.workTask?.value
        XCTAssertEqual(model.phase, .error(.network, retryFrom: .steps))
        model.retry()
        XCTAssertEqual(model.currentStepIndex, 0)
    }

    // MARK: - Multi-photo rounds

    private static let prompt = "გადაიღე მოხსნილი სიფონის შიგნითა მხარე ახლოდან"
    private static let needsPhoto = StepsContinuation.needsPhoto(prompt: prompt, reason: "შუასადები არ ჩანს.")
    private static let round2Parts = PartsResult(object: "მოხსნილი სიფონი", parts: [Part(id: "p1", name: "შუასადები", box: [380, 420, 620, 560])])
    private static let round2Steps = [
        Step(index: 1, title: "შუასადები", text: "შეამოწმე შუასადები", focus: ["p1"]),
        Step(index: 2, title: "დაბრუნება", text: "დააბრუნე სიფონი", focus: ["p1"]),
    ]

    /// Streams `steps` for the current round through stepsCalls[call] and ends with `continuation`.
    private func streamRound(call: Int, steps: [Step], continuation: StepsContinuation) async {
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == call + 1 }
        let stream = api.stepsContinuation(call)
        steps.forEach { stream.yield(.step($0)) }
        stream.yield(.done(nil, continuation: continuation))
        await model.workTask?.value
    }

    /// Round 1 finished with `.needsPhoto`, using the first two fixture steps.
    private func reachNeedsPhoto() async {
        await reachParts()
        await streamRound(call: 0, steps: Array(Fixtures.steps[...1]), continuation: Self.needsPhoto)
    }

    /// Round 2 scanned and streamed to completion.
    private func reachRound2Done() async {
        await reachNeedsPhoto()
        api.setParts(.success(Self.round2Parts))
        model.continueWithPhoto { Fixtures.keyframe }
        await model.workTask?.value
        await streamRound(call: 1, steps: Self.round2Steps, continuation: .complete)
    }

    func testRoundOneIsUnchangedAndComplete() async {
        await reachParts()
        await streamRound(call: 0, steps: Fixtures.steps, continuation: .complete)
        XCTAssertEqual(model.round, 1)
        XCTAssertEqual(model.continuation, .complete)
        XCTAssertFalse(model.canContinueWithPhoto)
        XCTAssertNil(model.pendingContext)
        XCTAssertNil(api.partsCalls[0].context)
        XCTAssertNil(api.stepsCalls[0].context)
        XCTAssertEqual(model.allSteps, Fixtures.steps)
        XCTAssertEqual(model.stepOffset, 0)
    }

    func testContinuationIsNilWhileStreamingAndCompleteWithoutDone() async {
        await reachParts()
        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 1 }
        api.stepsContinuation(0).yield(.step(Fixtures.steps[0]))
        await waitUntil { self.model.currentStep != nil }
        XCTAssertNil(model.continuation)
        api.stepsContinuation(0).finish()
        await model.workTask?.value
        XCTAssertEqual(model.continuation, .complete)
    }

    func testNeedsPhotoAllowsContinuing() async {
        await reachNeedsPhoto()
        XCTAssertEqual(model.continuation, Self.needsPhoto)
        XCTAssertTrue(model.canContinueWithPhoto)
        model.finish()
        XCTAssertFalse(model.canContinueWithPhoto, "only from finished steps")
    }

    func testContinueWithPhotoScansWithContextThenStreamsRoundTwo() async {
        await reachNeedsPhoto()
        model.next()
        api.setParts(.success(Self.round2Parts))
        let captures = Counter()
        model.continueWithPhoto { captures.increment(); return Data([1, 2]) }
        guard case .scanning = model.phase else { return XCTFail("expected scanning, got \(model.phase)") }
        XCTAssertEqual(model.round, 2)
        XCTAssertEqual(model.completedRounds, [SessionRound(number: 1, photoPrompt: nil, result: Fixtures.parts,
                                                            steps: Array(Fixtures.steps[...1]), continuation: Self.needsPhoto)])
        XCTAssertNil(model.continuation)
        let context = SessionContext(round: 2, photoPrompt: Self.prompt, doneSteps: ["წყალი", "ქანჩი"], previousObject: "ონკანი")
        XCTAssertEqual(model.pendingContext, context)

        await model.workTask?.value
        XCTAssertEqual(model.phase, .parts(Self.round2Parts))
        XCTAssertEqual(captures.value, 1)
        XCTAssertEqual(api.partsCalls.count, 2)
        XCTAssertEqual(api.partsCalls[1].keyframe, Data([1, 2]))
        XCTAssertEqual(api.partsCalls[1].context, context)
        XCTAssertEqual(api.partsCalls[1].instructions, "როგორ შევცვალო ონკანის ქანჩი?", "same instructions")

        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 2 }
        XCTAssertEqual(api.stepsCalls[1], .init(object: "მოხსნილი სიფონი", parts: Self.round2Parts.parts,
                                                instructions: "როგორ შევცვალო ონკანის ქანჩი?", context: context))
        XCTAssertEqual(model.currentStepIndex, 2, "the new round starts at its first global index")
        XCTAssertNil(model.currentStep, "no round-2 step yet")
        api.stepsContinuation(1).yield(.step(Self.round2Steps[0]))
        await waitUntil { self.model.currentStep != nil }
        XCTAssertEqual(model.currentStep, Self.round2Steps[0])
        XCTAssertEqual(model.displayedRound, 2)
        XCTAssertEqual(model.displayedResult, Self.round2Parts)
    }

    func testGlobalStepIndexCrossesRounds() async {
        await reachRound2Done()
        XCTAssertEqual(model.phase, .steps(Self.round2Parts, Self.round2Steps, streaming: false))
        XCTAssertEqual(model.stepOffset, 2)
        XCTAssertEqual(model.allSteps, Array(Fixtures.steps[...1]) + Self.round2Steps)
        XCTAssertEqual(model.currentStepIndex, 2)
        XCTAssertEqual(model.continuation, .complete)
        XCTAssertFalse(model.canContinueWithPhoto)

        model.next()
        model.next()
        XCTAssertEqual(model.currentStepIndex, 3, "bounded by allSteps")
        model.previous()
        model.previous()
        XCTAssertEqual(model.currentStepIndex, 1)
        XCTAssertEqual(model.currentStep, Fixtures.steps[1])
        XCTAssertEqual(model.displayedRound, 1)
        XCTAssertEqual(model.displayedResult, Fixtures.parts)
        model.previous()
        model.previous()
        XCTAssertEqual(model.currentStepIndex, 0)
        model.next()
        model.next()
        XCTAssertEqual(model.displayedRound, 2)
        XCTAssertEqual(model.displayedResult, Self.round2Parts)

        model.finish()
        XCTAssertEqual(model.phase, .done(Self.round2Parts, Self.round2Steps))
        XCTAssertEqual(model.allSteps.count, 4)
    }

    func testLastRoundForcesComplete() async {
        await reachNeedsPhoto()
        for round in 2...SessionModel.maxRounds {
            model.continueWithPhoto { Fixtures.keyframe }
            await model.workTask?.value
            XCTAssertEqual(model.round, round)
            XCTAssertEqual(api.partsCalls.last?.context?.round, round)
            XCTAssertEqual(api.partsCalls.last?.context?.doneSteps.count, (round - 1) * 2)
            await streamRound(call: round - 1, steps: Array(Fixtures.steps[...1]), continuation: Self.needsPhoto)
        }
        XCTAssertEqual(model.round, 5)
        XCTAssertEqual(model.continuation, .complete, "round 5 cannot ask for another photo")
        XCTAssertFalse(model.canContinueWithPhoto)
        model.continueWithPhoto { Fixtures.keyframe }
        XCTAssertEqual(api.partsCalls.count, 5)
        XCTAssertEqual(model.allSteps.count, 10)
    }

    func testRoundTwoRetriesKeepTheContext() async {
        await reachNeedsPhoto()
        api.setParts(.failure(URLError(.notConnectedToInternet)), .success(Self.round2Parts))
        model.continueWithPhoto { Fixtures.keyframe }
        await model.workTask?.value
        XCTAssertEqual(model.phase, .error(.network, retryFrom: .scan))
        XCTAssertEqual(model.completedRounds.count, 1, "a round-2 scan error keeps round 1")
        XCTAssertEqual(model.allSteps, Array(Fixtures.steps[...1]))
        XCTAssertEqual(model.stepOffset, 2)
        model.retry()
        await model.workTask?.value
        XCTAssertEqual(model.phase, .parts(Self.round2Parts))
        XCTAssertEqual(api.partsCalls.map(\.context?.round), [nil, 2, 2])
        XCTAssertEqual(api.stepsCalls.count, 1, "scan retry asks only for parts")

        model.startSteps()
        await waitUntil { self.api.stepsCalls.count == 2 }
        api.stepsContinuation(1).finish(throwing: URLError(.networkConnectionLost))
        await model.workTask?.value
        XCTAssertTrue(isError(.steps))
        XCTAssertEqual(model.allSteps, Array(Fixtures.steps[...1]), "a round-2 steps error keeps round 1's steps")
        model.retry()
        await waitUntil { self.api.stepsCalls.count == 3 }
        XCTAssertEqual(api.stepsCalls[2].context?.round, 2)
        XCTAssertEqual(api.partsCalls.count, 3, "steps retry does not scan again")
        XCTAssertEqual(model.currentStepIndex, 2)
        XCTAssertEqual(model.completedRounds.count, 1)
    }

    func testCancellingRoundTwoErrorReturnsToRoundOne() async {
        await reachNeedsPhoto()
        api.setParts(.failure(URLError(.notConnectedToInternet)))
        model.continueWithPhoto { Fixtures.keyframe }
        await model.workTask?.value
        XCTAssertTrue(isError(.scan))
        model.cancel()
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, Array(Fixtures.steps[...1]), streaming: false))
        XCTAssertEqual(model.round, 1)
        XCTAssertEqual(model.continuation, Self.needsPhoto)
        XCTAssertTrue(model.canContinueWithPhoto)
        XCTAssertEqual(model.currentStep, Fixtures.steps[1])
        XCTAssertEqual(api.partsCalls.count, 2)
    }

    func testCancellingRoundTwoScanReturnsToRoundOne() async {
        await reachNeedsPhoto()
        model.next()
        api.setParts(.hang)
        model.continueWithPhoto { Fixtures.keyframe }
        await waitUntil { self.api.partsCalls.count == 2 }
        model.cancel()
        XCTAssertEqual(model.phase, .steps(Fixtures.parts, Array(Fixtures.steps[...1]), streaming: false))
        XCTAssertEqual(model.round, 1)
        XCTAssertNil(model.pendingContext)
        XCTAssertEqual(model.continuation, Self.needsPhoto)
        XCTAssertTrue(model.canContinueWithPhoto)
        XCTAssertEqual(model.currentStep, Fixtures.steps[1])
    }

    func testBeginDescribingClearsRounds() async {
        await reachRound2Done()
        model.beginDescribing()
        XCTAssertEqual(model.phase, .describing(text: ""))
        XCTAssertEqual(model.completedRounds, [])
        XCTAssertNil(model.continuation)
        XCTAssertNil(model.pendingContext)
        XCTAssertEqual(model.round, 1)
        XCTAssertEqual(model.currentStepIndex, 0)
        XCTAssertEqual(model.allSteps, [])
    }
}

/// Thread-safe counter for `@Sendable` closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
