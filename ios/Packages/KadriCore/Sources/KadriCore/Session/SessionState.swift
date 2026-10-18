import Foundation

/// Where a session is. Every phase after `.parts` carries the parts so the UI never has to look elsewhere.
public enum SessionPhase: Equatable, Sendable {
    case idle
    /// The user is typing a short instruction over the camera.
    case describing(text: String)
    /// Keyframe captured or being captured; waiting for `POST /ai/parts`.
    case scanning(startedAt: Date)
    /// Parts are known; the phone segments and anchors them before steps are requested.
    case parts(PartsResult)
    /// Steps received so far. `streaming` stays true until the server's done event.
    case steps(PartsResult, [Step], streaming: Bool)
    case done(PartsResult, [Step])
    case error(SessionError, retryFrom: RetryPoint)
}

/// A finished response on the current photo; its context allows cancellation to restore it exactly.
public struct SessionTurn: Equatable, Sendable {
    public let steps: [Step]
    public let continuation: StepsContinuation
    public let context: SessionContext?
    public let answers: [SessionAnswer]
    public var image: Data? = nil
}

/// One finished photo of a multi-photo session.
public struct SessionRound: Equatable, Sendable {
    /// 1-based.
    public let number: Int
    /// The prompt the user followed to take this photo; nil for the first one.
    public let photoPrompt: String?
    public let result: PartsResult
    public let steps: [Step]
    public let continuation: StepsContinuation
    public var turns: [SessionTurn] = []
    public var context: SessionContext?
    public var answers: [SessionAnswer] = []
    public var keyframe: Data? = nil

    public init(number: Int, photoPrompt: String?, result: PartsResult, steps: [Step], continuation: StepsContinuation) {
        self.number = number
        self.photoPrompt = photoPrompt
        self.result = result
        self.steps = steps
        self.continuation = continuation
    }
}

/// The stage `SessionModel.retry()` restarts.
public enum RetryPoint: Equatable, Sendable {
    /// Capture a new keyframe and request parts again.
    case scan
    /// Keep the parts and request steps again.
    case steps
}

public enum SessionError: LocalizedError, Equatable, Sendable {
    case network
    case timeout
    case server(code: String, message: String)
    case unauthorized
    case cancelled
    case noParts

    public var errorDescription: String? {
        switch self {
        case .network:
            return "ინტერნეტთან კავშირი ვერ დამყარდა. შეამოწმეთ კავშირი და სცადეთ თავიდან."
        case .timeout:
            return "პასუხს ძალიან დიდი დრო დასჭირდა. სცადეთ თავიდან."
        case .server(_, let message):
            return message.isEmpty ? "სერვერის შეცდომა. სცადეთ თავიდან." : message
        case .unauthorized:
            return "სესიას ვადა გაუვიდა. გთხოვთ, თავიდან შეხვიდეთ."
        case .cancelled:
            return "მოთხოვნა გაუქმდა."
        case .noParts:
            return "კადრში ნაწილები ვერ ვიპოვე. მიუახლოვდით ობიექტს და სცადეთ თავიდან."
        }
    }

    /// Worker error body: `{"error":{"code":"…","message":"…"}}`.
    public struct ServerBody: Decodable, Sendable {
        public struct Detail: Decodable, Sendable {
            public let code: String
            public let message: String
        }
        public let error: Detail
    }

    /// Maps a non-2xx Worker response. 401 → `.unauthorized`, 504 / `ai_timeout` → `.timeout`,
    /// anything else → `.server` with the Worker's Georgian message (e.g. 429 `daily_limit`).
    public init(status: Int, body: Data?) {
        let detail = body.flatMap { try? JSONDecoder().decode(ServerBody.self, from: $0) }?.error
        if status == 401 || detail?.code == "unauthorized" {
            self = .unauthorized
        } else if status == 504 || detail?.code == "ai_timeout" {
            self = .timeout
        } else if let detail {
            self = .server(code: detail.code, message: detail.message)
        } else {
            self = .server(code: "http_\(status)", message: "")
        }
    }

    /// Maps any error thrown by a `KadriAPI` implementation.
    public init(_ error: any Error) {
        switch error {
        case let error as SessionError:
            self = error
        case is CancellationError:
            self = .cancelled
        case let error as URLError:
            switch error.code {
            case .timedOut: self = .timeout
            case .cancelled: self = .cancelled
            case .userAuthenticationRequired: self = .unauthorized
            default: self = .network
            }
        default:
            self = .network
        }
    }
}

/// Verification stays within the current photo round and reuses its parts.
public enum CheckPhotoPhase: Equatable, Sendable {
    case idle
    case requested(prompt: String, reason: String)
    case checking
}
