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
