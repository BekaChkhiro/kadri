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
        XCTAssertEqual(status(.parts(LiveCameraMockAPI.result)), .lookAgain)
        XCTAssertEqual(status(.parts(LiveCameraMockAPI.result), visible: 1, lost: true), .lookAgain)
        XCTAssertEqual(status(.error(.timeout, retryFrom: .scan)), .failed(SessionError.timeout.localizedDescription))
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
    var calls: [(Data, AIProvider?)] = []
    private var continuation: CheckedContinuation<Void, Never>?
    init(delayed: Bool = false) { self.delayed = delayed }

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
        return Self.result
    }
    func release() { continuation?.resume(); continuation = nil }
    nonisolated func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream {
            XCTFail("The live camera test must not request steps")
            $0.finish()
        }
    }
}
