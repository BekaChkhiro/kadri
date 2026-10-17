import Foundation
import XCTest
@testable import KadriCore

/// Scriptable `KadriAPI`. Each `parts` call takes the next behaviour from `partsBehaviors`
/// (the last one repeats); each `steps` call opens a stream the test drives through `stepsContinuation(_:)`.
final class MockKadriAPI: KadriAPI, @unchecked Sendable {
    enum PartsBehavior {
        case success(PartsResult)
        case failure(any Error)
        /// Never answers; only cancellation ends it.
        case hang
    }

    struct StepsCall: Equatable {
        let object: String
        let parts: [Part]
        let instructions: String
        var context: SessionContext? = nil
        var provider: AIProvider? = nil
    }

    private let lock = NSLock()
    private var _partsBehaviors: [PartsBehavior]
    private var _partsCalls: [(keyframe: Data, instructions: String, context: SessionContext?, provider: AIProvider?)] = []
    private var _stepsCalls: [StepsCall] = []
    private var _stepsContinuations: [AsyncThrowingStream<StepEvent, Error>.Continuation] = []
    private var _terminatedStreams = 0

    init(parts: PartsBehavior...) {
        _partsBehaviors = parts
    }

    var partsCalls: [(keyframe: Data, instructions: String, context: SessionContext?, provider: AIProvider?)] { lock.withLock { _partsCalls } }
    var stepsCalls: [StepsCall] { lock.withLock { _stepsCalls } }
    var terminatedStreams: Int { lock.withLock { _terminatedStreams } }

    func setParts(_ behaviors: PartsBehavior...) {
        lock.withLock { _partsBehaviors = behaviors }
    }

    func stepsContinuation(_ call: Int) -> AsyncThrowingStream<StepEvent, Error>.Continuation {
        lock.withLock { _stepsContinuations[call] }
    }

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        try await parts(keyframe: keyframe, instructions: instructions, context: context, provider: nil)
    }
    func parts(keyframe: Data, instructions: String, context: SessionContext?, provider: AIProvider?) async throws -> PartsResult {
        let behavior = lock.withLock { () -> PartsBehavior in
            _partsCalls.append((keyframe, instructions, context, provider))
            return _partsBehaviors.count > 1 ? _partsBehaviors.removeFirst() : _partsBehaviors[0]
        }
        switch behavior {
        case .success(let result):
            return result
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        steps(object: object, parts: parts, instructions: instructions, context: context, provider: nil)
    }
    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?, provider: AIProvider?) -> AsyncThrowingStream<StepEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<StepEvent, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self._terminatedStreams += 1 }
        }
        lock.withLock {
            _stepsCalls.append(StepsCall(object: object, parts: parts, instructions: instructions, context: context, provider: provider))
            _stepsContinuations.append(continuation)
        }
        return stream
    }
}

/// A manual clock: time moves only through `advance(by:)`.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .zero }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= _now {
                    lock.unlock()
                    continuation.resume()
                } else {
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [Sleeper] in
            _now = _now.advanced(by: duration)
            let due = sleepers.filter { $0.deadline <= _now }
            sleepers.removeAll { $0.deadline <= _now }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }
}

/// Polls `condition` on the main actor until it holds or two seconds pass.
@MainActor
func waitUntil(
    _ description: String = "condition",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    for _ in 0..<2000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(1))
    }
    XCTFail("Timed out waiting for \(description)", file: file, line: line)
}

enum Fixtures {
    static let parts = PartsResult(
        object: "ონკანი",
        parts: [
            Part(id: "p1", name: "სახელური", box: [100, 100, 300, 300]),
            Part(id: "p2", name: "ქანჩი", box: [400, 400, 600, 700]),
        ],
        latencyMs: 7000
    )
    static let steps = [
        Step(index: 1, title: "წყალი", text: "გადაკეტე წყალი", focus: ["p1"]),
        Step(index: 2, title: "ქანჩი", text: "მოხსენი ქანჩი", focus: ["p2"]),
        Step(index: 3, title: "შემოწმება", text: "გახსენი წყალი და შეამოწმე", focus: ["p1"]),
    ]
    static let keyframe = Data([0xFF, 0xD8, 0xFF])
}
