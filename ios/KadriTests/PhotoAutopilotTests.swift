import XCTest
import KadriCore
@testable import Kadri

@MainActor
final class PhotoAutopilotTests: XCTestCase {
    func testArguments() {
        let session = PhotoSession(api: MockKadriAPI())
        XCTAssertNil(PhotoAutopilot.fromArguments(["Kadri"], session: session))
        XCTAssertNil(PhotoAutopilot.fromArguments(["Kadri", "--autopilot", "--dev-token"], session: session))
        let pilot = try? XCTUnwrap(PhotoAutopilot.fromArguments(
            ["Kadri", "--autopilot", "/tmp/x", "--autopilot-step-delay", "0.25"], session: session))
        XCTAssertEqual(pilot?.directory.path, "/tmp/x")
        XCTAssertEqual(pilot?.stepDelay, 0.25)
        XCTAssertEqual(PhotoAutopilot.fromArguments(["Kadri", "--autopilot", "/tmp/x"], session: session)?.stepDelay, 3.5)
    }

    func testTwoPhotoRunWritesResultsAndDone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autopilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let demo = try XCTUnwrap(Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"))

        let session = PhotoSession(api: MockKadriAPI(scanDelay: .milliseconds(5), stepDelay: .milliseconds(5), multiPhoto: true))
        let pilot = PhotoAutopilot(session: session, directory: directory, stepDelay: 0.05, pollInterval: 0.02)
        pilot.start()
        defer { pilot.stop() }

        try await waitForFile("status.json", in: directory)
        XCTAssertEqual(try json("status.json", in: directory)["phase"] as? String, "describing")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(session.image, "waits for the photo and the comment")

        try "ნიჟარა ჟონავს".write(to: directory.appendingPathComponent("comment.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: demo, to: directory.appendingPathComponent("round-1.png"))

        try await waitForFile("round-1.result.json", in: directory)
        let first = try json("round-1.result.json", in: directory)
        XCTAssertEqual(first["round"] as? Int, 1)
        XCTAssertEqual(first["object"] as? String, MockKadriAPI.result.object)
        XCTAssertEqual((first["parts"] as? [[String: Any]])?.count, MockKadriAPI.result.parts.count)
        let firstSteps = try XCTUnwrap(first["steps"] as? [[String: Any]])
        XCTAssertEqual(firstSteps.map { $0["index"] as? Int }, [1, 2, 3])
        let continuation = try XCTUnwrap(first["continuation"] as? [String: Any])
        XCTAssertEqual(continuation["kind"] as? String, "needs_photo")
        XCTAssertEqual(continuation["prompt"] as? String, MockKadriAPI.round2Prompt)
        let timings = try XCTUnwrap(first["timings"] as? [String: Any])
        XCTAssertNotNil(timings["scanMs"] as? Int)
        XCTAssertNotNil(timings["stepsDoneMs"] as? Int)
        XCTAssertEqual(session.model.currentStepIndex, 2, "walked to the last step")

        try await waitFor("status waiting for round 2") {
            (try? self.json("status.json", in: directory)["waitingForPhoto"] as? Int) == 2
        }
        let status = try json("status.json", in: directory)
        XCTAssertEqual(status["phase"] as? String, "steps")
        XCTAssertEqual(status["stepIndex"] as? Int, 3)
        XCTAssertEqual(status["stepsCount"] as? Int, 3)
        XCTAssertNil(try? json("done.json", in: directory))

        try FileManager.default.copyItem(at: demo, to: directory.appendingPathComponent("round-2.png"))
        try await waitForFile("done.json", in: directory)
        let second = try json("round-2.result.json", in: directory)
        XCTAssertEqual(second["object"] as? String, MockKadriAPI.round2Result.object)
        XCTAssertEqual((second["steps"] as? [[String: Any]])?.map { $0["index"] as? Int }, [4, 5, 6])
        XCTAssertEqual((second["continuation"] as? [String: Any])?["kind"] as? String, "complete")
        guard case .done = session.model.phase else { return XCTFail("expected done, got \(session.model.phase)") }
        XCTAssertTrue(pilot.isStopped)
        try await waitFor("final status") { (try? self.json("status.json", in: directory)["phase"] as? String) == "done" }
        XCTAssertEqual(try json("status.json", in: directory)["round"] as? Int, 2)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testDiagnosticAnswersRunInsideOnePhotoRound() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("autopilot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let demo = try XCTUnwrap(Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"))

        let session = PhotoSession(api: DiagnosticAPI())
        let pilot = PhotoAutopilot(session: session, directory: directory, stepDelay: 0.05, pollInterval: 0.02)
        pilot.start()
        defer { pilot.stop() }

        try "აკუმულატორი ჯდება".write(to: directory.appendingPathComponent("comment.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: demo, to: directory.appendingPathComponent("round-1.png"))

        try await waitForFile("question-1.json", in: directory)
        let first = try json("question-1.json", in: directory)
        XCTAssertEqual(first["round"] as? Int, 1)
        XCTAssertEqual(first["turn"] as? Int, 1)
        XCTAssertEqual(first["kind"] as? String, "needs_answer")
        XCTAssertEqual(first["question"] as? String, DiagnosticAPI.question)
        XCTAssertEqual(first["options"] as? [String], DiagnosticAPI.options)
        XCTAssertEqual(first["allowOther"] as? Bool, true)
        XCTAssertEqual(first["stepsSoFar"] as? Int, 2)
        XCTAssertEqual(first["stepTitles"] as? [String], MockKadriAPI.sampleSteps.prefix(2).map(\.title))
        try await waitFor("status waiting for answer 1") {
            (try? self.json("status.json", in: directory)["waitingForAnswer"] as? Int) == 1
        }
        XCTAssertNil(try? json("round-1.result.json", in: directory), "the round is not over while a question is open")

        try "  \n".write(to: directory.appendingPathComponent("answer-1.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.model.answers.count, 0, "an empty answer is not sent")
        try "ღამით\n".write(to: directory.appendingPathComponent("answer-1.txt"), atomically: true, encoding: .utf8)

        try await waitForFile("question-2.json", in: directory)
        let second = try json("question-2.json", in: directory)
        XCTAssertEqual(second["turn"] as? Int, 2)
        XCTAssertEqual(second["kind"] as? String, "needs_measurement")
        XCTAssertEqual(second["unit"] as? String, "mA")
        XCTAssertEqual(second["min"] as? Double, 0)
        XCTAssertEqual(second["how"] as? String, DiagnosticAPI.how)
        XCTAssertEqual(second["stepsSoFar"] as? Int, 3, "the answer brought a new step")

        try "150".write(to: directory.appendingPathComponent("answer-2.txt"), atomically: true, encoding: .utf8)
        try await waitForFile("done.json", in: directory)

        let result = try json("round-1.result.json", in: directory)
        XCTAssertEqual((result["steps"] as? [[String: Any]])?.map { $0["index"] as? Int }, [1, 2, 3, 4])
        let turns = try XCTUnwrap(result["turns"] as? [[String: Any]])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns.map { $0["kind"] as? String }, ["needs_answer", "needs_measurement"])
        XCTAssertEqual(turns.map { $0["answer"] as? String }, ["ღამით", "150"])
        XCTAssertEqual(turns[1]["unit"] as? String, "mA")
        XCTAssertTrue(turns[0]["unit"] is NSNull)
        let continuation = try XCTUnwrap(result["continuation"] as? [String: Any])
        XCTAssertEqual(continuation["kind"] as? String, "complete")
        XCTAssertEqual(continuation["cause"] as? String, DiagnosticAPI.cause)
        XCTAssertEqual(continuation["summary"] as? String, DiagnosticAPI.summary)
        let timings = try XCTUnwrap(result["timings"] as? [String: Any])
        XCTAssertEqual((timings["turnFirstStepMs"] as? [Int])?.count, 2)

        let done = try json("done.json", in: directory)
        XCTAssertEqual(done["cause"] as? String, DiagnosticAPI.cause)
        XCTAssertEqual(done["answers"] as? Int, 2)
        XCTAssertEqual(done["rounds"] as? Int, 1)
        XCTAssertEqual(session.model.answers.map(\.unit), [nil, "mA"])
        XCTAssertTrue(pilot.isStopped)
    }

    // MARK: - Helpers

    private func json(_ name: String, in directory: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func waitForFile(_ name: String, in directory: URL) async throws {
        try await waitFor(name) { FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path) }
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else {
                throw NSError(domain: "PhotoAutopilotTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "timed out waiting for \(what)"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Plays needs_answer → needs_measurement → complete(cause) on one photo, keyed by how many answers were sent.
private struct DiagnosticAPI: KadriAPI {
    static let question = "როდის ჯდება აკუმულატორი?"
    static let options = ["ღამით", "მგზავრობისას", "ყოველთვის"]
    static let how = "მულტიმეტრი მიაერთე მინუს კლემასა და მავთულს შორის"
    static let cause = "პარაზიტული დენი"
    static let summary = "ღამით 150 mA იხარჯება."

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        try await Task.sleep(for: .milliseconds(5))
        return MockKadriAPI.result
    }

    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        let (steps, next): ([Step], StepsContinuation) = switch context?.answers.count ?? 0 {
        case 0: (Array(MockKadriAPI.sampleSteps.prefix(2)),
                 .needsAnswer(question: Self.question, options: Self.options, allowOther: true, reason: nil))
        case 1: ([MockKadriAPI.sampleSteps[2]],
                 .needsMeasurement(question: "რამდენი დენი იხარჯება?", unit: "mA", min: 0, max: 2000, how: Self.how, reason: nil))
        default: ([MockKadriAPI.sampleSteps[3]], .complete(cause: Self.cause, summary: Self.summary))
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in steps {
                        try await Task.sleep(for: .milliseconds(5))
                        continuation.yield(.step(step))
                    }
                    continuation.yield(.done(nil, continuation: next))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
