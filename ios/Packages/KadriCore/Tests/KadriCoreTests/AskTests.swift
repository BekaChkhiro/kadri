import XCTest
@testable import KadriCore

final class AskTests: XCTestCase {
    func testSafeDefaultsAndTypicalFitCheck() throws {
        let result = try JSONDecoder().decode(AskResult.self, from: Data(#"{"answer":"შეამოწმე","size":"32 მმ","sizeSource":"guessed","confidence":"certain"}"#.utf8))
        XCTAssertEqual(result.confidence, .low)
        XCTAssertEqual(result.sizeSource, "typical")
        XCTAssertFalse(try XCTUnwrap(result.fitCheck).isEmpty)
        XCTAssertNil(result.urgency)
        XCTAssertEqual(result.partLabel, "მონიშნული ნაწილი")
        XCTAssertThrowsError(try JSONDecoder().decode(AskResult.self, from: Data("{}".utf8)))
    }

    func testMultipartRequestAndUsage() async throws {
        let seen = Locked<(URLRequest, Data)?>(nil)
        let url = MockURLProtocol.register { request, data in
            seen.value = (request, data)
            return .json(200, #"{"partLabel":"ქანჩი","answer":"პასუხი","size":"32 მმ","sizeSource":"seen","urgency":"stop","confidence":"high","usage":{"input_tokens":10,"output_tokens":20},"costUsd":0.001,"latencyMs":23.6}"#)
        }
        let client = KadriClient(config: APIConfig(baseURL: url), auth: StaticToken(token: "tok"), session: MockURLProtocol.session())
        let jpeg = Data([0xff, 0xd8, 0xff])
        let result = try await client.ask(keyframe: jpeg, question: " ეს რა არის? ", box: [10, 20, 300, 400], partId: "p1", parts: [],
                                          context: AskContext(object: "სიფონი", doneSteps: ["გადაკეტე წყალი"]), provider: .gemini)
        XCTAssertEqual(result.confidence, .high)
        XCTAssertEqual(result.urgency, .stop)
        XCTAssertEqual(result.sizeSource, "seen")
        XCTAssertEqual(result.usage?.inputTokens, 10)
        XCTAssertEqual(result.usage?.latencyMs, 24)
        let (request, data) = try XCTUnwrap(seen.value)
        XCTAssertEqual(request.url?.path, "/ai/ask")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let body = String(decoding: data, as: UTF8.self)
        for (name, value) in [("question", "ეს რა არის?"), ("box", "[10,20,300,400]"), ("partId", "p1"), ("parts", "[]"), ("provider", "gemini")] {
            XCTAssertTrue(body.contains("name=\"\(name)\"\r\n\r\n\(value)\r\n"))
        }
        XCTAssertTrue(body.contains("\"object\":\"სიფონი\""))
        XCTAssertTrue(body.contains("\"doneSteps\":[\"გადაკეტე წყალი\"]"))
        XCTAssertNotNil(data.range(of: jpeg))
    }

    func testOptionalFieldsOmittedAndHTTPError() async throws {
        let url = MockURLProtocol.register { _, data in
            let body = String(decoding: data, as: UTF8.self)
            for name in ["partId", "context", "provider"] { XCTAssertFalse(body.contains("name=\"\(name)\"")) }
            return .json(401, #"{"error":{"code":"unauthorized","message":""}}"#)
        }
        let client = KadriClient(config: APIConfig(baseURL: url), auth: nil, session: MockURLProtocol.session())
        do {
            _ = try await client.ask(keyframe: Data(), question: "?", box: [0, 0, 100, 100], partId: nil, parts: [], context: nil, provider: nil)
            XCTFail("Expected unauthorized")
        } catch { XCTAssertEqual(error as? SessionError, .unauthorized) }
    }
}
