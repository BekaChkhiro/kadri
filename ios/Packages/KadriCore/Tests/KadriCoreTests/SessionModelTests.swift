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

    func testCancelAfterStreamingEndsSession() async {
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
}

/// Thread-safe counter for `@Sendable` closures.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}
