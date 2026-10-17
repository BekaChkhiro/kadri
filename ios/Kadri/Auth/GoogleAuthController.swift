import Foundation
import Observation
import UIKit

/// Google's half of sign-in: an ID token the Worker can verify. `GIDTokenProvider` on the phone, a mock in tests.
@MainActor
protocol GoogleTokenProvider: Sendable {
    /// Interactive sign-in. Throws `GoogleSignInFailure`.
    func signIn(presenting: UIViewController) async throws -> String
    /// A fresh ID token for an earlier sign-in without showing UI; nil when there is none.
    func restore() async -> String?
    func signOut()
}

enum GoogleSignInFailure: Error, Equatable {
    /// The user closed Google's sheet; not an error to show.
    case cancelled
    case noIDToken
    case failed
}

/// The Worker's half: exchanges the Google ID token for a session and checks it. `WorkerAuth` is the real one.
protocol WorkerSessionAuth: Sendable {
    func signIn(googleIDToken: String) async throws -> AuthUser
    /// `GET /me` with the stored session.
    func currentUser() async throws -> AuthUser
    func hasSession() async -> Bool
    func signOut() async
}

/// Google Sign-In → `POST /auth/google` → Worker session in the Keychain (`AuthStore`).
@MainActor
@Observable
final class GoogleAuthController {
    enum State: Equatable {
        case signedOut
        case signingIn
        case signedIn(AuthUser)
        case failed(SessionError)
    }

    /// Whether `/me` accepted the stored session.
    enum Verification: Equatable {
        case idle
        case checking
        case active
        case failed(SessionError)
    }

    private(set) var state: State = .signedOut
    private(set) var verification: Verification = .idle

    @ObservationIgnored private let google: any GoogleTokenProvider
    @ObservationIgnored private let worker: any WorkerSessionAuth

    init(google: any GoogleTokenProvider, worker: any WorkerSessionAuth) {
        self.google = google
        self.worker = worker
    }

    var user: AuthUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    /// Georgian text for the current failure, if any.
    var errorMessage: String? {
        if case .failed(let error) = state { return error.localizedDescription }
        return nil
    }

    func signIn(presenting: UIViewController) async {
        guard state != .signingIn else { return }
        state = .signingIn
        verification = .idle
        do {
            let idToken = try await google.signIn(presenting: presenting)
            state = .signedIn(try await worker.signIn(googleIDToken: idToken))
            verification = .active
        } catch GoogleSignInFailure.cancelled {
            state = .signedOut
        } catch {
            state = .failed(Self.sessionError(error))
        }
    }

    /// App start: reuse the Worker session if `/me` still accepts it, else exchange a silently restored Google token.
    func restorePreviousSignIn() async {
        guard state == .signedOut else { return }
        if await worker.hasSession(), let user = try? await worker.currentUser() {
            state = .signedIn(user)
            verification = .active
            return
        }
        guard let idToken = await google.restore() else { return }
        state = .signingIn
        do {
            state = .signedIn(try await worker.signIn(googleIDToken: idToken))
            verification = .active
        } catch {
            state = .failed(Self.sessionError(error))
        }
    }

    /// Asks `/me` whether the session is still alive. A rejected session signs the user out.
    func verifySession() async {
        guard case .signedIn = state else { return }
        verification = .checking
        do {
            state = .signedIn(try await worker.currentUser())
            verification = .active
        } catch {
            let error = Self.sessionError(error)
            if error == .unauthorized {
                google.signOut()
                await worker.signOut()
                state = .failed(.unauthorized)
                verification = .idle
            } else {
                verification = .failed(error)
            }
        }
    }

    func signOut() async {
        google.signOut()
        await worker.signOut()
        state = .signedOut
        verification = .idle
    }

    static let googleFailureMessage = "Google-ით შესვლა ვერ მოხერხდა. სცადეთ თავიდან."

    static func sessionError(_ error: any Error) -> SessionError {
        if error is GoogleSignInFailure {
            return .server(code: "google_sign_in", message: googleFailureMessage)
        }
        return SessionError(error)
    }
}

/// `WorkerSessionAuth` over `AuthStore` (session + refresh) and `GET /me`.
struct WorkerAuth: WorkerSessionAuth {
    let store: AuthStore
    let config: APIConfig
    let session: URLSession

    init(store: AuthStore, config: APIConfig, session: URLSession = .shared) {
        self.store = store
        self.config = config
        self.session = session
    }

    func signIn(googleIDToken: String) async throws -> AuthUser {
        try await store.signIn(googleIDToken: googleIDToken)
    }

    func currentUser() async throws -> AuthUser {
        var request = URLRequest(url: config.baseURL.appendingPathComponent("me"), timeoutInterval: config.requestTimeout)
        request.setValue("Bearer \(try await store.validToken())", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SessionError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SessionError(status: status, body: data) }
        guard let body = try? JSONDecoder().decode(MeBody.self, from: data) else {
            throw SessionError.server(code: "bad_response", message: "")
        }
        return body.user
    }

    func hasSession() async -> Bool {
        await store.isSignedIn
    }

    func signOut() async {
        await store.signOut()
    }

    private struct MeBody: Decodable {
        let user: AuthUser
    }
}

/// Keeps Google SDK work on the main actor and lets AuthStore coalesce silent recovery.
@MainActor
enum LiveAuth {
    static func store(config: APIConfig, storage: any TokenStorage,
                      google: any GoogleTokenProvider = GIDTokenProvider(),
                      session: URLSession? = nil) -> AuthStore {
        AuthStore(config: config, storage: storage, session: session, reauthenticate: {
            guard let idToken = await google.restore() else { return nil }
            let recovered = InMemoryTokenStorage()
            let exchange = AuthStore(config: config, storage: recovered, session: session)
            try await exchange.signIn(googleIDToken: idToken)
            return try recovered.load()
        })
    }
}
