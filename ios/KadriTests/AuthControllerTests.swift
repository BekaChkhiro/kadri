import UIKit
import SwiftUI
import XCTest
@testable import Kadri

/// GoogleAuthController against a mock Google and the real AuthStore over a mock Worker (URLProtocol).
@MainActor
final class AuthControllerTests: XCTestCase {
    private var google: MockGoogle!
    private var storage: InMemoryTokenStorage!
    private var controller: GoogleAuthController!

    override func setUp() async throws {
        WorkerStub.reset()
        google = MockGoogle()
        storage = InMemoryTokenStorage()
        let config = APIConfig(baseURL: URL(string: "https://worker.test")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkerStub.self]
        let session = URLSession(configuration: configuration)
        let store = AuthStore(config: config, storage: storage, session: session)
        controller = GoogleAuthController(google: google, worker: WorkerAuth(store: store, config: config, session: session))
    }

    func testLiveAuthSilentlyRestoresGoogleAndExchangesExpiredSession() async throws {
        try storage.save(StoredSession(token: "expired", expiresAt: .distantPast))
        google.restoredToken = "restored-google-token"
        WorkerStub.routes["/auth/google"] = (200, Self.signInBody(token: "recovered"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkerStub.self]
        let auth = LiveAuth.store(config: APIConfig(baseURL: URL(string: "https://worker.test")!),
                                  storage: storage, google: google, session: URLSession(configuration: configuration))
        let token = try await auth.validToken()
        XCTAssertEqual(token, "recovered")
        XCTAssertEqual(google.restoreCount, 1)
        XCTAssertNil(WorkerStub.authorization["/auth/refresh"])
        let body = try XCTUnwrap(WorkerStub.bodies["/auth/google"])
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["idToken": "restored-google-token"])
    }

    func testLiveAuthWithoutGoogleSessionRequiresSignIn() async {
        let auth = LiveAuth.store(config: APIConfig(baseURL: URL(string: "https://worker.test")!),
                                  storage: storage, google: google)
        do {
            _ = try await auth.validToken()
            XCTFail("Expected unauthorized")
        } catch { XCTAssertEqual(error as? SessionError, .unauthorized) }
        XCTAssertEqual(google.restoreCount, 1)
        XCTAssertTrue(WorkerStub.bodies.isEmpty)
    }

    func testPhotoUnauthorizedScreenKeepsPhotoAndRendersRecoveryActions() async throws {
        let photo = PhotoSession(api: MockKadriAPI())
        photo.selectDemo()
        photo.model.updateText("ნიჟარა ჟონავს")
        photo.model.submit { throw SessionError.unauthorized }
        try await Task.sleep(for: .milliseconds(100))
        guard case .error(.unauthorized, _) = photo.model.phase else {
            return XCTFail("Expected unauthorized photo screen")
        }
        XCTAssertNotNil(photo.image)
        let host = UIHostingController(rootView: PhotoFlowView(session: photo).environment(controller))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/kadri-reauth-error.png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "Photo unauthorized recovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSuccessfulSignInStoresWorkerSession() async throws {
        google.token = "google-id-token"
        WorkerStub.routes["/auth/google"] = (200, Self.signInBody(token: "session-1"))

        await controller.signIn(presenting: UIViewController())

        XCTAssertEqual(controller.user?.email, "nino@example.com")
        XCTAssertEqual(controller.verification, .active)
        XCTAssertEqual(try storage.load()?.token, "session-1")
        let sent = try XCTUnwrap(WorkerStub.bodies["/auth/google"])
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: sent), ["idToken": "google-id-token"])
    }

    func testWorkerRejectionFailsWithGeorgianMessage() async throws {
        google.token = "google-id-token"
        WorkerStub.routes["/auth/google"] = (401, Data(#"{"error":{"code":"unauthorized","message":"invalid"}}"#.utf8))

        await controller.signIn(presenting: UIViewController())

        XCTAssertEqual(controller.state, .failed(.unauthorized))
        XCTAssertEqual(controller.errorMessage, "სესიას ვადა გაუვიდა. გთხოვთ, თავიდან შეხვიდეთ.")
        XCTAssertNil(try storage.load())
    }

    func testWorkerServerErrorKeepsItsGeorgianMessage() async {
        google.token = "google-id-token"
        WorkerStub.routes["/auth/google"] = (500, Data(#"{"error":{"code":"internal","message":"სერვერზე შეცდომაა"}}"#.utf8))

        await controller.signIn(presenting: UIViewController())

        XCTAssertEqual(controller.errorMessage, "სერვერზე შეცდომაა")
    }

    func testGoogleFailureAndCancel() async {
        google.failure = .failed
        await controller.signIn(presenting: UIViewController())
        XCTAssertEqual(controller.errorMessage, GoogleAuthController.googleFailureMessage)
        XCTAssertTrue(WorkerStub.bodies.isEmpty)

        google.failure = .cancelled
        await controller.signIn(presenting: UIViewController())
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertNil(controller.errorMessage)
    }

    func testSignOutClearsEverything() async throws {
        google.token = "google-id-token"
        WorkerStub.routes["/auth/google"] = (200, Self.signInBody(token: "session-1"))
        await controller.signIn(presenting: UIViewController())

        await controller.signOut()

        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertEqual(controller.verification, .idle)
        XCTAssertNil(try storage.load())
        XCTAssertEqual(google.signOutCount, 1)
    }

    func testRestoreReusesStoredSessionViaMe() async throws {
        try storage.save(StoredSession(token: "stored", expiresAt: Date().addingTimeInterval(3600)))
        let config = APIConfig(baseURL: URL(string: "https://worker.test")!)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WorkerStub.self]
        let session = URLSession(configuration: configuration)
        let store = AuthStore(config: config, storage: storage, session: session)
        controller = GoogleAuthController(google: google, worker: WorkerAuth(store: store, config: config, session: session))
        WorkerStub.routes["/me"] = (200, Data(#"{"user":{"id":"u1","email":"nino@example.com","name":null,"picture":null}}"#.utf8))

        await controller.restorePreviousSignIn()

        XCTAssertEqual(controller.user?.email, "nino@example.com")
        XCTAssertEqual(controller.verification, .active)
        XCTAssertEqual(WorkerStub.authorization["/me"], "Bearer stored")
        XCTAssertEqual(google.restoreCount, 0)
    }

    func testRestoreWithoutAnythingStaysSignedOut() async {
        await controller.restorePreviousSignIn()
        XCTAssertEqual(controller.state, .signedOut)
        XCTAssertEqual(google.restoreCount, 1)
    }

    func testVerifyRejectedSessionSignsOut() async throws {
        google.token = "google-id-token"
        WorkerStub.routes["/auth/google"] = (200, Self.signInBody(token: "session-1"))
        await controller.signIn(presenting: UIViewController())
        WorkerStub.routes["/me"] = (401, Data(#"{"error":{"code":"unauthorized","message":""}}"#.utf8))

        await controller.verifySession()

        XCTAssertEqual(controller.state, .failed(.unauthorized))
        XCTAssertNil(try storage.load())
    }

    private static func signInBody(token: String) -> Data {
        let expires = ISO8601DateFormatter().string(from: Date().addingTimeInterval(7 * 24 * 3600))
        return Data("""
        {"sessionToken":"\(token)","expiresAt":"\(expires)","user":{"id":"u1","email":"nino@example.com","name":"ნინო","picture":null}}
        """.utf8)
    }
}

@MainActor
private final class MockGoogle: GoogleTokenProvider {
    var token = "token"
    var failure: GoogleSignInFailure?
    var signOutCount = 0
    var restoreCount = 0
    var restoredToken: String?

    func signIn(presenting: UIViewController) async throws -> String {
        if let failure { throw failure }
        return token
    }

    func restore() async -> String? {
        restoreCount += 1
        return restoredToken
    }

    func signOut() {
        signOutCount += 1
    }
}

/// Answers Worker requests by path; records bodies and Authorization headers.
private final class WorkerStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var routes: [String: (Int, Data)] = [:]
    nonisolated(unsafe) static var bodies: [String: Data] = [:]
    nonisolated(unsafe) static var authorization: [String: String] = [:]

    static func reset() {
        routes = [:]
        bodies = [:]
        authorization = [:]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if let body = request.httpBody ?? request.httpBodyStream.map(Self.read) { Self.bodies[path] = body }
        Self.authorization[path] = request.value(forHTTPHeaderField: "Authorization")
        let (status, data) = Self.routes[path] ?? (404, Data(#"{"error":{"code":"not_found","message":""}}"#.utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
