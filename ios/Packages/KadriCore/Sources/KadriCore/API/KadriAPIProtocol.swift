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

/// One event of the `POST /ai/steps` SSE stream.
public enum StepEvent: Hashable, Sendable {
    /// A finished step; steps arrive one at a time, in order.
    case step(Step)
    /// The stream is complete.
    case done(StepsUsage?)
}

/// The Worker's AI endpoints. Implementations throw `SessionError` where they can
/// (see `SessionError.init(status:body:)`); anything else is mapped by `SessionError.init(_:)`.
public protocol KadriAPI: Sendable {
    /// `POST /ai/parts` with a JPEG keyframe and the user's short instruction text.
    func parts(keyframe: Data, instructions: String) async throws -> PartsResult

    /// `POST /ai/steps`, streamed. Cancelling the consuming task must cancel the request.
    func steps(object: String, parts: [Part], instructions: String) -> AsyncThrowingStream<StepEvent, Error>
}
