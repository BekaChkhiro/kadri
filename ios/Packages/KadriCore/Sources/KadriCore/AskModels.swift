import Foundation

public struct AskContext: Codable, Sendable, Hashable {
    public var object: String?
    public var doneSteps: [String]?
    public var answers: [SessionAnswer]?
    public init(object: String? = nil, doneSteps: [String]? = nil, answers: [SessionAnswer]? = nil) {
        self.object = object; self.doneSteps = doneSteps; self.answers = answers
    }
}

public struct AskResult: Decodable, Sendable, Hashable {
    public let partLabel: String
    public let answer: String
    public let size: String?
    public let sizeSource: String?
    public let fitCheck: String?
    public let urgency: AskUrgency?
    public let suggestStep: String?
    public let confidence: AskConfidence
    public let usage: StepsUsage?

    public init(partLabel: String, answer: String, size: String? = nil, sizeSource: String? = nil,
                fitCheck: String? = nil, urgency: AskUrgency? = nil, suggestStep: String? = nil,
                confidence: AskConfidence = .low, usage: StepsUsage? = nil) {
        self.partLabel = partLabel; self.answer = answer; self.size = size
        self.sizeSource = size == nil ? nil : (["seen", "model"].contains(sizeSource ?? "") ? sizeSource : "typical")
        self.fitCheck = self.sizeSource == "typical" && (fitCheck?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            ? "შეადარე ხელსაწყო ადგილზე: უნდა ჩაჯდეს თამაშის გარეშე" : fitCheck
        self.urgency = urgency; self.suggestStep = suggestStep; self.confidence = confidence; self.usage = usage
    }

    private enum CodingKeys: String, CodingKey {
        case partLabel, answer, size, sizeSource, fitCheck, urgency, suggestStep, confidence, usage, costUsd, latencyMs
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let usage = try? c.decode(DoneBody.Usage.self, forKey: .usage)
        self.init(partLabel: (try? c.decode(String.self, forKey: .partLabel)) ?? "მონიშნული ნაწილი",
                  answer: try c.decode(String.self, forKey: .answer),
                  size: try? c.decode(String.self, forKey: .size),
                  sizeSource: try? c.decode(String.self, forKey: .sizeSource),
                  fitCheck: try? c.decode(String.self, forKey: .fitCheck),
                  urgency: try? c.decode(AskUrgency.self, forKey: .urgency),
                  suggestStep: try? c.decode(String.self, forKey: .suggestStep),
                  confidence: (try? c.decode(AskConfidence.self, forKey: .confidence)) ?? .low,
                  usage: StepsUsage(inputTokens: usage?.input_tokens, outputTokens: usage?.output_tokens,
                                    reasoningTokens: usage?.output_tokens_details?.reasoning_tokens,
                                    costUsd: try? c.decode(Double.self, forKey: .costUsd),
                                    latencyMs: (try? c.decode(Double.self, forKey: .latencyMs)).map { Int($0.rounded()) }))
    }
}


/// How soon a finding needs attention. Unknown wire values decode as `.soon`.
public enum AskUrgency: String, Codable, Sendable, CaseIterable {
    case ok, soon, stop

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .soon
    }
}

/// How sure the AI is about a meaning. Anything but `.high` is a guess the user should check;
/// unknown wire values decode as `.low`.
public enum AskConfidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low

    public init(from decoder: any Decoder) throws {
        self = Self(rawValue: (try? decoder.singleValueContainer().decode(String.self)) ?? "") ?? .low
    }
}
