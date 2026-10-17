import Foundation

/// Result of `POST /ai/parts`: the object the AI recognised and its parts.
public struct PartsResult: Hashable, Codable, Sendable {
    public let object: String
    public let parts: [Part]
    public let latencyMs: Int?

    public init(object: String, parts: [Part], latencyMs: Int? = nil) {
        self.object = object
        self.parts = parts
        self.latencyMs = latencyMs
    }
}

/// Token and cost accounting the server sends with the final steps event. Every field is optional.
public struct StepsUsage: Hashable, Codable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let costUsd: Double?
    public let latencyMs: Int?

    public init(
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        costUsd: Double? = nil,
        latencyMs: Int? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.costUsd = costUsd
        self.latencyMs = latencyMs
    }
}

/// What the server says should happen after the steps of one photo.
/// Wire: `{"kind":"complete"}` or `{"kind":"needs_photo","prompt":"…","reason":"…"}`.
/// An unknown kind, an empty prompt or anything unreadable decodes as `.complete`.
public enum StepsContinuation: Hashable, Sendable, Decodable {
    case complete
    /// The next steps need a new photo; `prompt` says what to shoot, `reason` why.
    case needsPhoto(prompt: String, reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, prompt, reason
    }

    public init(from decoder: any Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              (try? c.decode(String.self, forKey: .kind)) == "needs_photo",
              let prompt = try? c.decode(String.self, forKey: .prompt),
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            self = .complete
            return
        }
        self = .needsPhoto(prompt: prompt, reason: (try? c.decode(String.self, forKey: .reason)) ?? "")
    }
}

/// Sent with round 2+ of a multi-photo session so the stateless Worker knows what already happened.
public struct SessionContext: Hashable, Codable, Sendable {
    /// 2…`SessionModel.maxRounds`.
    public let round: Int
    /// The `needs_photo` prompt the user followed to take this photo.
    public let photoPrompt: String
    /// Titles of every step shown so far, in order.
    public let doneSteps: [String]
    /// The previous photo's object.
    public let previousObject: String?

    public init(round: Int, photoPrompt: String, doneSteps: [String], previousObject: String? = nil) {
        self.round = round
        self.photoPrompt = photoPrompt
        self.doneSteps = doneSteps
        self.previousObject = previousObject
    }
}

/// One event of the `POST /ai/steps` SSE stream.
public enum StepEvent: Hashable, Sendable {
    /// A finished step; steps arrive one at a time, in order.
    case step(Step)
    /// The stream is complete.
    case done(StepsUsage?, continuation: StepsContinuation = .complete)
}

/// The Worker's AI endpoints. Implementations throw `SessionError` where they can
/// (see `SessionError.init(status:body:)`); anything else is mapped by `SessionError.init(_:)`.
public protocol KadriAPI: Sendable {
    /// `POST /ai/parts` with a JPEG keyframe and the user's short instruction text.
    /// `context` is nil for the first photo of a session.
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult

    /// `POST /ai/steps`, streamed. Cancelling the consuming task must cancel the request.
    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error>
}

extension KadriAPI {
    /// First photo of a session.
    public func parts(keyframe: Data, instructions: String) async throws -> PartsResult {
        try await parts(keyframe: keyframe, instructions: instructions, context: nil)
    }

    /// First photo of a session.
    public func steps(object: String, parts: [Part], instructions: String) -> AsyncThrowingStream<StepEvent, Error> {
        steps(object: object, parts: parts, instructions: instructions, context: nil)
    }
}
