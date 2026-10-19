import XCTest
import simd
@testable import Kadri
@testable import KadriCore

final class LiveCameraTests: XCTestCase {
    private let viewport = CGSize(width: 300, height: 500)
    private var projection: PartProjection {
        PartProjection(id: "p1", center: CGPoint(x: 100, y: 100),
                       corners: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 50),
                                 CGPoint(x: 150, y: 150), CGPoint(x: 50, y: 150)], returnErrorPixels: nil)
    }

    func testTrackingLossAndStaleFramesHideEveryMarker() {
        XCTAssertEqual(LiveTrackingPolicy.visible([projection], viewport: viewport, trackingNormal: true, frameAge: 0.1).count, 1)
        XCTAssertTrue(LiveTrackingPolicy.visible([projection], viewport: viewport, trackingNormal: false, frameAge: 0.1).isEmpty)
        XCTAssertTrue(LiveTrackingPolicy.visible([projection], viewport: viewport, trackingNormal: true, frameAge: 0.5).isEmpty)
        XCTAssertTrue(LiveTrackingPolicy.visible([projection], viewport: viewport, trackingNormal: true, frameAge: -1).isEmpty)
    }

    func testOffscreenAndInvalidProjectionsHaveNoFixedFallback() {
        let outside = PartProjection(id: "p1", center: CGPoint(x: -20, y: 100), corners: projection.corners, returnErrorPixels: nil)
        let invalid = PartProjection(id: "p2", center: CGPoint(x: CGFloat.nan, y: 100), corners: projection.corners, returnErrorPixels: nil)
        XCTAssertTrue(LiveTrackingPolicy.visible([outside, invalid], viewport: viewport, trackingNormal: true, frameAge: 0).isEmpty)
        XCTAssertTrue(LiveTrackingPolicy.visible([], viewport: viewport, trackingNormal: true, frameAge: 0).isEmpty)
    }

    func testGuessedDepthAndSparseSurfaceSamplesAreRejected() {
        func placement(_ confidence: Float) -> PartPlacement {
            PartPlacement(id: "p1", anchorID: UUID(), worldPosition: .zero, box: [0, 0, 100, 100],
                          confidence: confidence, worldCorners: [], referenceCenter: .zero)
        }
        XCTAssertFalse(LiveTrackingPolicy.supportedPlacement(placement(0)))
        XCTAssertFalse(LiveTrackingPolicy.supportedPlacement(placement(0.4)))
        XCTAssertFalse(LiveTrackingPolicy.supportedPlacement(placement(.nan)))
        XCTAssertTrue(LiveTrackingPolicy.supportedPlacement(placement(0.6)))
    }

    func testLargeViewChangeRequiresRecognitionAgain() {
        XCTAssertTrue(LiveTrackingPolicy.sameView(reference: matrix_identity_float4x4, current: matrix_identity_float4x4))
        var moved = matrix_identity_float4x4
        moved.columns.3.x = 0.31
        XCTAssertFalse(LiveTrackingPolicy.sameView(reference: matrix_identity_float4x4, current: moved))
        let turned = simd_float4x4(simd_quatf(angle: .pi / 3, axis: SIMD3(0, 1, 0)))
        XCTAssertFalse(LiveTrackingPolicy.sameView(reference: matrix_identity_float4x4, current: turned))
    }

    func testKeyframePickerRejectsMissingStableHistory() async {
        do {
            _ = try await KeyframePicker().pick([])
            XCTFail("No frame must never become an AI keyframe")
        } catch KeyframePicker.Failure.unstable {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testFailedCaptureCannotReuseAnOlderKeyframe() {
        XCTAssertTrue(LiveTrackingPolicy.freshKeyframe(timestamp: 10, previous: 9, now: 10.1))
        XCTAssertFalse(LiveTrackingPolicy.freshKeyframe(timestamp: 10, previous: 10, now: 10.1))
        XCTAssertFalse(LiveTrackingPolicy.freshKeyframe(timestamp: 10, previous: 9, now: 10.5))
        XCTAssertFalse(LiveTrackingPolicy.freshKeyframe(timestamp: 10, previous: nil, now: 9))
    }

    func testStatusPrioritizesLostTrackingOverOldResults() {
        func status(_ phase: SessionPhase, visible: Int = 0, lost: Bool = false, waiting: Bool = false) -> LiveCameraStatus {
            LiveCameraStatus.resolve(supported: true, permissionDenied: false, needsRecognition: lost,
                                     waitingForKeyframe: waiting, phase: phase, visibleCount: visible)
        }
        XCTAssertEqual(status(.describing(text: ""), waiting: true), .steady)
        XCTAssertEqual(status(.scanning(startedAt: Date())), .recognizing)
        XCTAssertEqual(status(.parts(LiveCameraMockAPI.result), visible: 1), .tracked(1))
        XCTAssertEqual(status(.parts(LiveCameraMockAPI.result)), .surfaceUnavailable)
        XCTAssertEqual(status(.parts(LiveCameraMockAPI.result), visible: 1, lost: true), .lookAgain)
        XCTAssertEqual(status(.error(.timeout, retryFrom: .scan)), .failed(SessionError.timeout.localizedDescription))
    }

    func testPlacementReportSeparatesRejectionReasons() {
        let parts = (1...6).map {
            Part(id: "p\($0)", name: "ნაწილი", box: $0 == 5 ? [0, 0, 0, 0] : [100, 100, 400, 400])
        }
        let placements = zip(["p1", "p2", "p3", "p4"], [Float(0.8), 0, 0.3, .nan]).map { id, confidence in
            PartPlacement(id: id, anchorID: UUID(), worldPosition: .zero, box: [100, 100, 400, 400],
                          confidence: confidence, worldCorners: [], referenceCenter: .zero)
        }
        XCTAssertEqual(LivePlacementReport.make(parts: parts, placements: placements),
                       LivePlacementReport(parts: 6, accepted: 1, noDepth: 2, weakDepth: 1, invalidBox: 1, noPlacement: 1))
    }

    func testLocalPlacementRetriesAreSpacedAndBounded() {
        var retry = LivePlacementRetry()
        XCTAssertFalse(retry.shouldAttempt(now: 10))
        retry.begin(now: 10)
        XCTAssertFalse(retry.shouldAttempt(now: 9))
        for second in 10..<22 {
            XCTAssertTrue(retry.shouldAttempt(now: Double(second)))
            retry.didAttempt(now: Double(second))
            XCTAssertFalse(retry.shouldAttempt(now: Double(second) + 0.9))
        }
        XCTAssertEqual(retry.attempts, 12)
        XCTAssertTrue(retry.expired(now: 22))
        XCTAssertFalse(retry.shouldAttempt(now: 30))
        retry.begin(now: 40)
        XCTAssertEqual(retry.attempts, 0)
        XCTAssertTrue(retry.shouldAttempt(now: 40))
    }

    func testSurfaceSearchOffscreenAndTrackingLossHaveDistinctStatuses() {
        func status(visible: Int = 0, searching: Bool = false, placed: Int = 0,
                    recovery: LiveRecoveryReason? = nil) -> LiveCameraStatus {
            LiveCameraStatus.resolve(supported: true, permissionDenied: false, needsRecognition: recovery != nil,
                                     waitingForKeyframe: false, phase: .parts(LiveCameraMockAPI.result),
                                     visibleCount: visible, recovery: recovery,
                                     findingSurface: searching, placedCount: placed)
        }
        XCTAssertEqual(status(searching: true), .findingSurface)
        XCTAssertEqual(status(), .surfaceUnavailable)
        XCTAssertEqual(status(placed: 1), .outOfView)
        XCTAssertEqual(status(visible: 1, searching: true, placed: 1), .tracked(1))
        for reason in [LiveRecoveryReason.paused, .trackingLost, .staleFrame, .missingFrame, .viewChanged] {
            XCTAssertEqual(status(visible: 1, placed: 1, recovery: reason), .recovery(reason))
            XCTAssertNotEqual(LiveCameraStatus.recovery(reason).text, LiveCameraStatus.surfaceUnavailable.text)
        }
    }

    @MainActor func testGeminiRecognitionStaysAtPartsWithoutStartingSteps() async {
        let api = LiveCameraMockAPI()
        let session = LiveCameraSession(api: api)
        session.instructions = "ამიხსენი ნაწილები"
        let jpeg = Data([1, 2, 3])
        session.submit(keyframe: jpeg)
        await session.model.workTask?.value
        XCTAssertEqual(session.model.phase, .parts(LiveCameraMockAPI.result))
        XCTAssertFalse(session.waitingForKeyframe)
        let calls = await api.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, jpeg)
        XCTAssertEqual(calls.first?.1, .gemini)
        session.phaseChanged()
        XCTAssertEqual(session.model.phase, .parts(LiveCameraMockAPI.result))
        XCTAssertEqual(session.placementReport.parts, 1)
        XCTAssertEqual(session.placementReport.noPlacement, 1)
        XCTAssertFalse(session.needsRecognition)
        session.phaseChanged()
        let repeatedCalls = await api.calls
        XCTAssertEqual(repeatedCalls.count, 1)
        XCTAssertTrue(session.model.allSteps.isEmpty)
        session.stop()
        XCTAssertNil(session.model.partsResult)
        XCTAssertTrue(session.needsRecognition)
        XCTAssertTrue(session.tracker.contours.isEmpty)
    }

    @MainActor func testLateAPIResponseCannotRestoreStoppedSession() async {
        let api = LiveCameraMockAPI(delayed: true)
        let session = LiveCameraSession(api: api)
        session.submit(keyframe: Data([1]))
        let work = session.model.workTask
        await fulfillment(of: [api.requested], timeout: 2)
        session.stop()
        await api.release()
        await work?.value
        XCTAssertNil(session.model.partsResult)
        XCTAssertEqual(session.model.phase, .describing(text: ""))
        XCTAssertTrue(session.needsRecognition)
    }

    @MainActor func testEmptyAIResultHasItsOwnDiagnosticReason() async {
        let api = LiveCameraMockAPI(empty: true)
        let session = LiveCameraSession(api: api)
        session.submit(keyframe: Data([1]))
        await session.model.workTask?.value
        session.phaseChanged()
        XCTAssertEqual(session.model.phase, .error(.noParts, retryFrom: .scan))
        XCTAssertTrue(session.diagnosticLine.contains("reason no_parts"))
        XCTAssertTrue(session.diagnosticLine.contains("parts 0"))
        XCTAssertFalse(session.findingSurface)
        let calls = await api.calls
        XCTAssertEqual(calls.count, 1)
    }

    @MainActor func testSimulatorDoesNotStartAROrCallAPI() async {
        let api = LiveCameraMockAPI()
        let session = LiveCameraSession(api: api)
        guard !session.controller.supported else { return }
        await session.start()
        session.update()
        XCTAssertEqual(session.status(visibleCount: 0), .unavailable)
        XCTAssertNil(session.controller.latest)
        let calls = await api.calls
        XCTAssertTrue(calls.isEmpty)
    }
}

private actor LiveCameraMockAPI: KadriAPI {
    static let result = PartsResult(object: "ონკანი", parts: [Part(id: "p1", name: "სახელური", box: [100, 100, 400, 400])])
    nonisolated let requested = XCTestExpectation(description: "Mock parts requested")
    let delayed: Bool
    let empty: Bool
    var calls: [(Data, AIProvider?)] = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(delayed: Bool = false, empty: Bool = false) { self.delayed = delayed; self.empty = empty }

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        try await parts(keyframe: keyframe, instructions: instructions, context: context, provider: nil)
    }
    func parts(keyframe: Data, instructions: String, context: SessionContext?, provider: AIProvider?) async throws -> PartsResult {
        calls.append((keyframe, provider))
        if delayed {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                requested.fulfill()
            }
        } else { requested.fulfill() }
        return empty ? PartsResult(object: "ობიექტი", parts: []) : Self.result
    }
    func release() { continuation?.resume(); continuation = nil }
    nonisolated func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream {
            XCTFail("The live camera test must not request steps")
            $0.finish()
        }
    }
}
