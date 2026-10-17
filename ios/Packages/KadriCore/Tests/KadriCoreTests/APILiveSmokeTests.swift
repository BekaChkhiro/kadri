import XCTest
@testable import KadriCore

/// Free smoke test against a running Worker. Skipped unless `KADRI_LIVE_URL` is set, e.g.
/// `KADRI_LIVE_URL=http://127.0.0.1:8799 swift test --filter APILiveSmokeTests`.
/// Only `/health` — the `/ai/*` routes are paid and are not called here.
final class APILiveSmokeTests: XCTestCase {
    func testHealthThroughRealURLSession() async throws {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["KADRI_LIVE_URL"])
        let client = KadriClient(config: APIConfig(baseURL: try XCTUnwrap(URL(string: raw))), auth: nil)
        let health = try await client.health()
        XCTAssertTrue(health.ok)
    }

    override func setUpWithError() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["KADRI_LIVE_URL"]?.isEmpty ?? true, "KADRI_LIVE_URL not set")
    }
}
