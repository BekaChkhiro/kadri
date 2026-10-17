import Foundation

/// Where the Worker lives and how long to wait for it.
public struct APIConfig: Hashable, Sendable {
    /// Info.plist key holding the Worker's base URL, e.g. `http://192.168.1.20:8797` for a local `wrangler dev`.
    public static let infoPlistKey = "KADRI_API_URL"

    public var baseURL: URL
    /// Idle timeout for AI requests. The Worker gives up after 60 s (`AI_TIMEOUT_MS`) and answers 504,
    /// so this stays above it to receive that answer instead of a client-side timeout.
    public var aiTimeout: TimeInterval
    /// Timeout for auth and other quick requests.
    public var requestTimeout: TimeInterval

    public init(baseURL: URL, aiTimeout: TimeInterval = 75, requestTimeout: TimeInterval = 20) {
        self.baseURL = baseURL
        self.aiTimeout = aiTimeout
        self.requestTimeout = requestTimeout
    }

    /// Reads `KADRI_API_URL` from the bundle's Info.plist; nil when missing or not an http(s) URL.
    public static func fromBundle(_ bundle: Bundle = .main) -> APIConfig? {
        guard let raw = bundle.object(forInfoDictionaryKey: infoPlistKey) as? String,
              let url = URL(string: raw.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return nil }
        return APIConfig(baseURL: url)
    }

    func url(_ path: String) -> URL {
        baseURL.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
    }
}
