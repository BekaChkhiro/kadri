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
    case complete(cause: String?, summary: String?)
    case needsPhoto(prompt: String, reason: String)
    case needsAnswer(question: String, options: [String], allowOther: Bool, reason: String?)
    case needsMeasurement(question: String, unit: String, min: Double?, max: Double?, how: String, reason: String?)

    public static let complete = Self.complete(cause: nil, summary: nil)
    public var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind, prompt, reason, cause, summary, question, options, allowOther, unit, min, max, how
    }

    public init(from decoder: any Decoder) throws {
        self = .complete
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let kind = try? c.decode(String.self, forKey: .kind) else { return }
        func text(_ key: CodingKeys) -> String? { try? c.decode(String.self, forKey: key) }
        func nonempty(_ value: String) -> Bool { !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        do {
            let reason = try c.decodeIfPresent(String.self, forKey: .reason)
            switch kind {
            case "complete":
                self = .complete(cause: try c.decodeIfPresent(String.self, forKey: .cause),
                                 summary: try c.decodeIfPresent(String.self, forKey: .summary))
            case "needs_photo":
                guard let prompt = text(.prompt), nonempty(prompt) else { return }
                self = .needsPhoto(prompt: prompt, reason: reason ?? "")
            case "needs_answer":
                guard let question = text(.question), nonempty(question),
                      let options = try? c.decode([String].self, forKey: .options),
                      (2...4).contains(options.count), options.allSatisfy(nonempty),
                      let allowOther = try? c.decode(Bool.self, forKey: .allowOther) else { return }
                self = .needsAnswer(question: question, options: options, allowOther: allowOther, reason: reason)
            case "needs_measurement":
                guard let question = text(.question), nonempty(question), let unit = text(.unit), nonempty(unit),
                      let how = text(.how) else { return }
                self = .needsMeasurement(question: question, unit: unit,
                                         min: try c.decodeIfPresent(Double.self, forKey: .min),
                                         max: try c.decodeIfPresent(Double.self, forKey: .max), how: how, reason: reason)
            default: break
            }
        } catch { self = .complete }
    }
}

public struct SessionAnswer: Hashable, Codable, Sendable {
    public let question: String
    public let answer: String
    public let unit: String?

    public init(question: String, answer: String, unit: String? = nil) {
        self.question = question
        self.answer = answer
        self.unit = unit
    }
}

/// Context across both photo rounds and answer turns.
public struct SessionContext: Hashable, Codable, Sendable {
    public let round: Int
    public let photoPrompt: String
    public let doneSteps: [String]
    public let previousObject: String?
    public let answers: [SessionAnswer]

    public init(round: Int, photoPrompt: String, doneSteps: [String], previousObject: String? = nil,
                answers: [SessionAnswer] = []) {
        self.round = round
        self.photoPrompt = photoPrompt
        self.doneSteps = doneSteps
        self.previousObject = previousObject
        self.answers = answers
    }

    private enum CodingKeys: String, CodingKey { case round, photoPrompt, doneSteps, previousObject, answers }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        round = try c.decode(Int.self, forKey: .round)
        photoPrompt = try c.decodeIfPresent(String.self, forKey: .photoPrompt) ?? ""
        doneSteps = try c.decode([String].self, forKey: .doneSteps)
        previousObject = try c.decodeIfPresent(String.self, forKey: .previousObject)
        answers = try c.decodeIfPresent([SessionAnswer].self, forKey: .answers) ?? []
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(round, forKey: .round)
        if !photoPrompt.isEmpty { try c.encode(photoPrompt, forKey: .photoPrompt) }
        try c.encode(doneSteps, forKey: .doneSteps)
        try c.encodeIfPresent(previousObject, forKey: .previousObject)
        try c.encode(answers, forKey: .answers)
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
