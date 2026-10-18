import XCTest
@testable import KadriCore

final class AuthStoreTests: XCTestCase {
    func testPhotoRequestsRefreshTokensWithLessThanTwoMinutesRemainingBeforeSending() async throws {
        for path in ["/ai/parts", "/ai/steps"] {
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let storage = InMemoryTokenStorage(StoredSession(token: "old", expiresAt: now.addingTimeInterval(119)))
            let requests = Locked<[String]>([])
            let expiry = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
            let config = APIConfig(baseURL: MockURLProtocol.register { request, _ in
                requests.value.append(request.url!.path)
                if request.url?.path == "/auth/refresh" {
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old")
                    return .json(200, #"{"sessionToken":"fresh","expiresAt":"\#(expiry)"}"#)
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
                return .json(200, path == "/ai/parts" ? #"{"object":"o","parts":[]}"# : "event: done\ndata: {}\n\n")
            })
            let session = MockURLProtocol.session()
            defer { session.invalidateAndCancel() }
            // Keep the existing five-minute margin, which also covers the requested two minutes.
            let auth = AuthStore(config: config, storage: storage, session: session, now: { now })
            let api = KadriClient(config: config, auth: auth, session: session)
            if path == "/ai/parts" {
                _ = try await api.parts(keyframe: Data([1]), instructions: "x")
            } else {
                for try await _ in api.steps(object: "o", parts: [], instructions: "x") {}
            }
            XCTAssertEqual(requests.value, ["/auth/refresh", path])
            XCTAssertEqual(try storage.load()?.token, "fresh")
        }
    }
}
