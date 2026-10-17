import Foundation
import XCTest
@testable import KadriCore

final class SessionErrorTests: XCTestCase {
    private func body(_ code: String, _ message: String) -> Data {
        Data(#"{"error":{"code":"\#(code)","message":"\#(message)"}}"#.utf8)
    }

    func testWorkerStatusMapping() {
        XCTAssertEqual(SessionError(status: 401, body: body("unauthorized", "შედით")), .unauthorized)
        XCTAssertEqual(SessionError(status: 504, body: body("ai_timeout", "დრო ამოიწურა")), .timeout)
        XCTAssertEqual(SessionError(status: 502, body: body("ai_timeout", "x")), .timeout)
        XCTAssertEqual(
            SessionError(status: 429, body: body("daily_limit", "დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ")),
            .server(code: "daily_limit", message: "დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ")
        )
        XCTAssertEqual(SessionError(status: 500, body: Data("oops".utf8)), .server(code: "http_500", message: ""))
        XCTAssertEqual(SessionError(status: 503, body: nil), .server(code: "http_503", message: ""))
    }

    func testThrownErrorMapping() {
        XCTAssertEqual(SessionError(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(SessionError(URLError(.timedOut)), .timeout)
        XCTAssertEqual(SessionError(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(SessionError(CancellationError()), .cancelled)
        XCTAssertEqual(SessionError(SessionError.noParts), .noParts)
    }

    func testMessagesAreGeorgian() throws {
        let all: [SessionError] = [.network, .timeout, .server(code: "x", message: ""), .unauthorized, .cancelled, .noParts]
        for error in all {
            let text = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(text.unicodeScalars.contains { (0x10D0...0x10FF).contains($0.value) }, "\(error): \(text)")
        }
        XCTAssertEqual(SessionError.server(code: "daily_limit", message: "ლიმიტი").errorDescription, "ლიმიტი")
    }
}
