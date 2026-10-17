import XCTest
@testable import KadriCore

final class APIAuthStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private func store(
        _ storage: InMemoryTokenStorage,
        now: Date? = nil,
        _ handler: @escaping MockURLProtocol.Handler
    ) -> AuthStore {
        let fixed = now ?? t0
        return AuthStore(
            config: APIConfig(baseURL: MockURLProtocol.register(handler)),
            storage: storage,
            session: MockURLProtocol.session(),
            now: { fixed }
        )
    }

    func testSignInStoresSessionAndReturnsUser() async throws {
        let storage = InMemoryTokenStorage()
        let seen = Locked<(URLRequest, Data)?>(nil)
        let auth = store(storage) { request, body in
            seen.value = (request, body)
            return .json(200, """
            {"sessionToken":"s1","expiresAt":"\(self.iso(self.t0.addingTimeInterval(3600)))",
             "user":{"id":"g-1","email":"a@b.ge","name":"ბექა","picture":null}}
            """)
        }
        let user = try await auth.signIn(googleIDToken: "google-jwt")
        XCTAssertEqual(user, AuthUser(id: "g-1", email: "a@b.ge", name: "ბექა", picture: nil))
        XCTAssertEqual(try storage.load(), StoredSession(token: "s1", expiresAt: t0.addingTimeInterval(3600)))
        let isSignedIn = await auth.isSignedIn
        XCTAssertTrue(isSignedIn)
        let token = try await auth.validToken()
        XCTAssertEqual(token, "s1")

        let (request, body) = try XCTUnwrap(seen.value)
        XCTAssertEqual(request.url?.path, "/auth/google")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["idToken": "google-jwt"])
    }

    func testSignInRejectedIsUnauthorizedAndStoresNothing() async {
        let storage = InMemoryTokenStorage()
        let auth = store(storage) { _, _ in .json(401, #"{"error":{"code":"unauthorized","message":"ავტორიზაცია საჭიროა"}}"#) }
        do {
            try await auth.signIn(googleIDToken: "bad")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SessionError, .unauthorized)
        }
        XCTAssertNil(try storage.load())
    }

    func testFreshTokenIsReturnedWithoutNetwork() async throws {
        let storage = InMemoryTokenStorage(StoredSession(token: "old", expiresAt: t0.addingTimeInterval(6 * 60)))
        let auth = store(storage) { _, _ in XCTFail("no refresh expected"); return .json(500, "") }
        let token = try await auth.validToken()
        XCTAssertEqual(token, "old")
    }

    func testTokenExpiringWithinFiveMinutesIsRefreshedOnce() async throws {
        let storage = InMemoryTokenStorage(StoredSession(token: "old", expiresAt: t0.addingTimeInterval(4 * 60)))
        let calls = Locked<[String?]>([])
        let auth = store(storage) { request, _ in
            XCTAssertEqual(request.url?.path, "/auth/refresh")
            calls.value.append(request.value(forHTTPHeaderField: "Authorization"))
            Thread.sleep(forTimeInterval: 0.1)
            return .json(200, #"{"sessionToken":"new","expiresAt":"\#(self.iso(self.t0.addingTimeInterval(3600)))"}"#)
        }
        async let a = auth.validToken()
        async let b = auth.validToken()
        let tokens = try await [a, b]
        XCTAssertEqual(tokens, ["new", "new"])
        XCTAssertEqual(calls.value, ["Bearer old"], "concurrent callers share one refresh")
        XCTAssertEqual(try storage.load()?.token, "new")
        let again = try await auth.validToken()
        XCTAssertEqual(again, "new")
    }

    func testRefreshRejectedSignsOut() async throws {
        let storage = InMemoryTokenStorage(StoredSession(token: "old", expiresAt: t0.addingTimeInterval(60)))
        let auth = store(storage) { _, _ in .json(401, #"{"error":{"code":"unauthorized","message":"x"}}"#) }
        do {
            _ = try await auth.validToken()
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SessionError, .unauthorized)
        }
        XCTAssertNil(try storage.load())
        let isSignedIn = await auth.isSignedIn
        XCTAssertFalse(isSignedIn)
    }

    func testRefreshOfflineFallsBackToStillValidToken() async throws {
        let storage = InMemoryTokenStorage(StoredSession(token: "old", expiresAt: t0.addingTimeInterval(60)))
        let auth = store(storage) { _, _ in MockURLProtocol.Reply(chunks: [], failure: URLError(.notConnectedToInternet)) }
        let token = try await auth.validToken()
        XCTAssertEqual(token, "old")
        XCTAssertEqual(try storage.load()?.token, "old")
    }

    func testExpiredOrMissingSessionIsUnauthorizedWithoutNetwork() async {
        for initial in [nil, StoredSession(token: "old", expiresAt: t0.addingTimeInterval(-1))] {
            let storage = InMemoryTokenStorage(initial)
            let auth = store(storage) { _, _ in XCTFail("no request expected"); return .json(500, "") }
            do {
                _ = try await auth.validToken()
                XCTFail("expected throw")
            } catch {
                XCTAssertEqual(error as? SessionError, .unauthorized)
            }
            XCTAssertNil(try storage.load())
        }
    }

    func testExpiredSessionReauthenticatesOnceForConcurrentRequests() async throws {
        let fresh = StoredSession(token: "recovered", expiresAt: t0.addingTimeInterval(3600))
        let storage = InMemoryTokenStorage(StoredSession(token: "expired", expiresAt: t0))
        let calls = Locked(0)
        let fixed = t0
        let config = APIConfig(baseURL: MockURLProtocol.register { request, _ in
            XCTAssertEqual(request.url?.path, "/ai/parts")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer recovered")
            return .json(200, #"{"object":"sink","parts":[]}"#)
        })
        let auth = AuthStore(config: config, storage: storage, now: { fixed }, reauthenticate: {
            calls.value += 1
            try await Task.sleep(for: .milliseconds(100))
            return fresh
        })
        let client = KadriClient(config: config, auth: auth, session: MockURLProtocol.session())
        async let a = client.parts(keyframe: Data([1]), instructions: "a")
        async let b = client.parts(keyframe: Data([2]), instructions: "b")
        let results = try await [a, b]
        XCTAssertEqual(results.map(\.object), ["sink", "sink"])
        XCTAssertEqual(calls.value, 1)
        XCTAssertEqual(try storage.load(), fresh)
    }

    func testFailedOrMissingGoogleRestoreIsUnauthorized() async throws {
        for throwsError in [false, true] {
            let storage = InMemoryTokenStorage(StoredSession(token: "expired", expiresAt: t0))
            let fixed = t0
            let auth = AuthStore(config: APIConfig(baseURL: URL(string: "https://unused.test")!),
                                 storage: storage, now: { fixed }, reauthenticate: {
                if throwsError { throw URLError(.notConnectedToInternet) }
                return nil
            })
            do {
                _ = try await auth.validToken()
                XCTFail("Expected unauthorized")
            } catch { XCTAssertEqual(error as? SessionError, .unauthorized) }
            XCTAssertNil(try storage.load())
        }
    }

    func testInteractiveSignInInAnotherStoreIsPickedUp() async throws {
        let storage = InMemoryTokenStorage()
        let auth = store(storage) { _, _ in XCTFail("No refresh expected"); return .json(500, "") }
        try storage.save(StoredSession(token: "interactive", expiresAt: t0.addingTimeInterval(3600)))
        let token = try await auth.validToken()
        XCTAssertEqual(token, "interactive")
    }

    func testSignOutClearsStorage() async throws {
        let storage = InMemoryTokenStorage(StoredSession(token: "s", expiresAt: t0.addingTimeInterval(3600)))
        let auth = store(storage) { _, _ in .json(500, "") }
        await auth.signOut()
        XCTAssertNil(try storage.load())
        let isSignedIn = await auth.isSignedIn
        XCTAssertFalse(isSignedIn)
    }

    func testISO8601WithAndWithoutFractionalSeconds() {
        XCTAssertEqual(parseISO8601("2027-01-15T06:46:40.250Z"), Date(timeIntervalSince1970: 1_799_995_600.25))
        XCTAssertEqual(parseISO8601("2027-01-15T08:00:00.000Z"), parseISO8601("2027-01-15T08:00:00Z"))
        XCTAssertNil(parseISO8601("tomorrow"))
    }

    func testStoredSessionRoundTripsThroughCodable() throws {
        let s = StoredSession(token: "t", expiresAt: t0)
        XCTAssertEqual(try JSONDecoder().decode(StoredSession.self, from: JSONEncoder().encode(s)), s)
    }
}
