import Foundation
import Security

/// The Worker session the phone holds (`POST /auth/google` and `/auth/refresh`).
public struct StoredSession: Hashable, Codable, Sendable {
    public let token: String
    public let expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

/// The signed-in user as the Worker returns it.
public struct AuthUser: Hashable, Codable, Sendable {
    public let id: String
    public let email: String
    public let name: String?
    public let picture: String?
}

/// Where `AuthStore` keeps the session. Keychain on the phone; in-memory in tests and previews.
public protocol TokenStorage: Sendable {
    func load() throws -> StoredSession?
    func save(_ session: StoredSession) throws
    func clear() throws
}

/// Generic-password Keychain item, readable after first unlock, never synced off the device.
public struct KeychainTokenStorage: TokenStorage {
    public let service: String
    public let account: String

    public init(service: String = "ge.kadri.app", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> StoredSession? {
        var item: CFTypeRef?
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw KeychainError(status: status) }
        // A corrupt item is as good as none: the user just signs in again.
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, Hashable, Sendable {
    public let status: OSStatus
}

public final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init(_ session: StoredSession? = nil) {
        self.session = session
    }

    public func load() throws -> StoredSession? { lock.withLock { session } }
    public func save(_ session: StoredSession) throws { lock.withLock { self.session = session } }
    public func clear() throws { lock.withLock { session = nil } }
}

/// Holds the Worker session and keeps it fresh: `validToken()` refreshes it when it expires
/// within `refreshMargin`. Concurrent callers share one refresh.
public actor AuthStore: TokenProviding {
    private let config: APIConfig
    private let session: URLSession
    private let storage: any TokenStorage
    private let now: @Sendable () -> Date
    private let refreshMargin: TimeInterval
    private var current: StoredSession?
    private var refreshing: Task<StoredSession, Error>?

    public init(
        config: APIConfig,
        storage: any TokenStorage = KeychainTokenStorage(),
        session: URLSession? = nil,
        refreshMargin: TimeInterval = 5 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
        self.storage = storage
        self.session = session ?? .kadri(config)
        self.refreshMargin = refreshMargin
        self.now = now
        self.current = try? storage.load()
    }

    public var isSignedIn: Bool { current.map { $0.expiresAt > now() } ?? false }

    /// `POST /auth/google` with the ID token from Google Sign-In.
    @discardableResult
    public func signIn(googleIDToken: String) async throws -> AuthUser {
        var request = URLRequest(url: config.url("/auth/google"), timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["idToken": googleIDToken])
        let body = try decodeResponse(SignInBody.self, from: try await session.kadriData(for: request))
        try store(try body.session())
        return body.user
    }

    /// A token valid for at least `refreshMargin` (or until expiry if refreshing failed on the network).
    /// Throws `.unauthorized` when there is no usable session.
    public func validToken() async throws -> String {
        guard let current, current.expiresAt > now() else {
            try? clearSession()
            throw SessionError.unauthorized
        }
        if current.expiresAt.timeIntervalSince(now()) > refreshMargin { return current.token }
        do {
            return try await refresh(current).token
        } catch SessionError.unauthorized {
            try? clearSession()
            throw SessionError.unauthorized
        } catch {
            // Offline or server hiccup: the old token still works until it expires.
            if let latest = self.current, latest.expiresAt > now() { return latest.token }
            throw error
        }
    }

    public func signOut() {
        refreshing?.cancel()
        refreshing = nil
        try? clearSession()
    }

    private func refresh(_ old: StoredSession) async throws -> StoredSession {
        if let refreshing { return try await refreshing.value }
        var request = URLRequest(url: config.url("/auth/refresh"), timeoutInterval: config.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(old.token)", forHTTPHeaderField: "Authorization")
        let session = self.session
        let task = Task {
            try decodeResponse(SessionBody.self, from: try await session.kadriData(for: request)).session()
        }
        refreshing = task
        defer { refreshing = nil }
        let fresh = try await task.value
        try store(fresh)
        return fresh
    }

    private func store(_ session: StoredSession) throws {
        current = session
        try storage.save(session)
    }

    private func clearSession() throws {
        current = nil
        try storage.clear()
    }
}

// MARK: - Wire types

private struct SessionBody: Decodable {
    let sessionToken: String
    let expiresAt: String

    func session() throws -> StoredSession {
        guard let date = parseISO8601(expiresAt) else { throw SessionError.server(code: "bad_response", message: "") }
        return StoredSession(token: sessionToken, expiresAt: date)
    }
}

private struct SignInBody: Decodable {
    let sessionToken: String
    let expiresAt: String
    let user: AuthUser

    func session() throws -> StoredSession {
        try SessionBody(sessionToken: sessionToken, expiresAt: expiresAt).session()
    }
}

/// The Worker sends `Date.toISOString()`: `2026-10-17T12:00:00.000Z`.
func parseISO8601(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
