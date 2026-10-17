import Foundation
import KadriCore

/// Debug tokens use separate storage so a local session never replaces Google sign-in.
enum DevAuth {
    static func token(arguments: [String], defaults: String?, plist: String?) -> String? {
        if let index = arguments.firstIndex(of: "--dev-token") {
            guard arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else { return nil }
            return cleaned(arguments[index + 1])
        }
        return cleaned(defaults) ?? cleaned(plist)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    static func session(token: String, now: Date = Date()) throws -> StoredSession {
        let pieces = token.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3 else { throw SessionError.unauthorized }
        var payload = String(pieces[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        struct Claims: Decodable { let exp: Double }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              claims.exp.isFinite, claims.exp > now.timeIntervalSince1970 else { throw SessionError.unauthorized }
        return StoredSession(token: token, expiresAt: Date(timeIntervalSince1970: claims.exp))
    }

    static func storage() throws -> any TokenStorage {
        #if DEBUG
        if let token = token(arguments: ProcessInfo.processInfo.arguments,
                             defaults: UserDefaults.standard.string(forKey: "KADRI_DEV_TOKEN"),
                             plist: Bundle.main.object(forInfoDictionaryKey: "KADRI_DEV_TOKEN") as? String) {
            return InMemoryTokenStorage(try session(token: token))
        }
        #endif
        return KeychainTokenStorage()
    }
}
