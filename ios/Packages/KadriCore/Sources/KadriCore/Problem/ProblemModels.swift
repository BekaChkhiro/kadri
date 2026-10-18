import Foundation

public struct ProblemPhoto: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, CaseIterable, Sendable { case overview, detail, label, after }
    public let id: String
    public let image: Data
    public var note: String
    public var role: Role
    public init(id: String = UUID().uuidString, image: Data, note: String = "", role: Role = .detail) {
        self.id = id; self.image = image; self.note = note; self.role = role
    }
}
public struct ProblemHistory: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable, CaseIterable { case done, unable, unchanged }
    public let stepId: String
    public let title: String
    public let photoId: String
    public let outcome: Outcome
    public let note: String
    public init(stepId: String, title: String, photoId: String, outcome: Outcome, note: String = "") {
        self.stepId = stepId; self.title = title; self.photoId = photoId; self.outcome = outcome; self.note = note
    }
}
public struct ProblemAnswer: Codable, Hashable, Sendable {
    public let question: String
    public let answer: String
    public init(question: String, answer: String) { self.question = question; self.answer = answer }
}
public struct ProblemRequest: Codable, Hashable, Sendable {
    public let problem: String
    public let photos: [ProblemPhoto]
    public let history: [ProblemHistory]
    public let answers: [ProblemAnswer]
    public let previousComponents: [ProblemComponent]
    public let resolutionConfirmed: Bool
    public let provider: AIProvider?
    public let sessionId: String?
    public init(problem: String, photos: [ProblemPhoto], history: [ProblemHistory] = [], answers: [ProblemAnswer] = [], previousComponents: [ProblemComponent] = [], resolutionConfirmed: Bool = false, provider: AIProvider? = nil, sessionId: String? = nil) {
        self.problem = problem; self.photos = photos; self.history = history; self.answers = answers
        self.previousComponents = previousComponents; self.resolutionConfirmed = resolutionConfirmed
        self.provider = provider; self.sessionId = sessionId
    }
}
public struct ProblemComponent: Codable, Hashable, Sendable, Identifiable {
    public struct View: Codable, Hashable, Sendable {
        public let photoId: String
        public let box: [Int]
        public init(photoId: String, box: [Int]) { self.photoId = photoId; self.box = box }
    }
    public let id: String
    public let name: String
    public let views: [View]
    public init(id: String, name: String, views: [View]) { self.id = id; self.name = name; self.views = views }
}
public struct ProblemObservation: Codable, Hashable, Sendable {
    public let photoId: String
    public let detail: String
    public let relevance: String
    public init(photoId: String, detail: String, relevance: String) { self.photoId = photoId; self.detail = detail; self.relevance = relevance }
}
public struct ProblemLink: Codable, Hashable, Sendable {
    public enum Relation: String, Codable, Sendable { case sameSystem = "same_system", connected, uncertain }
    public let fromId: String
    public let toId: String
    public let relation: Relation
    public let evidencePhotoIds: [String]
    public let reason: String
    public init(fromId: String, toId: String, relation: Relation, evidencePhotoIds: [String], reason: String) {
        self.fromId = fromId; self.toId = toId; self.relation = relation; self.evidencePhotoIds = evidencePhotoIds; self.reason = reason
    }
}
public struct ProblemStep: Codable, Hashable, Sendable, Identifiable {
    public struct Arrow: Codable, Hashable, Sendable {
        public let type: String
        public let dir: String
        public init(type: String, dir: String) { self.type = type; self.dir = dir }
    }
    public let id: String
    public let title: String
    public let text: String
    public let photoId: String
    public let componentIds: [String]
    public let arrow: Arrow?
    public let warning: String?
    public let tool: String?
    public init(id: String, title: String, text: String, photoId: String, componentIds: [String], arrow: Arrow? = nil, warning: String? = nil, tool: String? = nil) {
        self.id = id; self.title = title; self.text = text; self.photoId = photoId; self.componentIds = componentIds
        self.arrow = arrow; self.warning = warning; self.tool = tool
    }
}
public struct ProblemNext: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case needsAnswer = "needs_answer", needsPhoto = "needs_photo", verify, resolved, unresolved }
    public let kind: Kind
    public let prompt: String
    public let reason: String
    public init(kind: Kind, prompt: String, reason: String) { self.kind = kind; self.prompt = prompt; self.reason = reason }
}
public struct ProblemResult: Codable, Hashable, Sendable {
    public let summary: String
    public let observations: [ProblemObservation]
    public let components: [ProblemComponent]
    public let links: [ProblemLink]
    public let steps: [ProblemStep]
    public let next: ProblemNext
    public init(summary: String, observations: [ProblemObservation], components: [ProblemComponent], links: [ProblemLink], steps: [ProblemStep], next: ProblemNext) {
        self.summary = summary; self.observations = observations; self.components = components; self.links = links; self.steps = steps; self.next = next
    }

    /// Reject hallucinated references before any part box or directional arrow is rendered.
    public func validate(for request: ProblemRequest) throws {
        func require(_ valid: Bool) throws {
            if !valid { throw SessionError.server(code: "invalid_problem_result", message: "პასუხში ფოტოებისა და კომპონენტების კავშირი ვერ დადასტურდა.") }
        }
        let photoIds = Set(request.photos.map(\.id))
        let componentIds = Set(components.map(\.id))
        try require(!summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        try require(componentIds.count == components.count && components.count <= 15)
        try require(observations.allSatisfy { ["relevant", "uncertain", "unrelated"].contains($0.relevance) && !$0.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        try require(Set(observations.map(\.photoId)) == photoIds && observations.count == photoIds.count)
        for component in components {
            try require(!component.id.isEmpty && !component.name.isEmpty && !component.views.isEmpty)
            try require(Set(component.views.map(\.photoId)).count == component.views.count)
            for view in component.views {
                try require(photoIds.contains(view.photoId) && view.box.count == 4)
                try require(view.box.allSatisfy { (0...1000).contains($0) })
                try require(view.box[0] < view.box[2] && view.box[1] < view.box[3])
            }
        }
        for link in links {
            try require(componentIds.contains(link.fromId) && componentIds.contains(link.toId) && link.fromId != link.toId)
            try require(!link.evidencePhotoIds.isEmpty && Set(link.evidencePhotoIds).isSubset(of: photoIds))
            try require(Set(link.evidencePhotoIds).count == link.evidencePhotoIds.count && !link.reason.isEmpty)
            for componentId in [link.fromId, link.toId] {
                try require(components.contains { $0.id == componentId && $0.views.contains { link.evidencePhotoIds.contains($0.photoId) } })
            }
            if link.relation != .uncertain {
                try require(link.evidencePhotoIds.allSatisfy { id in observations.contains { $0.photoId == id && $0.relevance == "relevant" } })
            }
        }
        try require(Set(steps.map(\.id)).count == steps.count && steps.count <= 5)
        for step in steps {
            try require(!request.history.contains { $0.stepId == step.id })
            try require(Set(step.componentIds).count == step.componentIds.count)
            try require(!step.id.isEmpty && !step.title.isEmpty && !step.text.isEmpty && photoIds.contains(step.photoId) && !step.componentIds.isEmpty)
            try require(Set(step.componentIds).isSubset(of: componentIds))
            try require(step.componentIds.allSatisfy { id in components.contains { $0.id == id && $0.views.contains { $0.photoId == step.photoId } } })
            try require(observations.contains { $0.photoId == step.photoId && $0.relevance == "relevant" })
            if let arrow = step.arrow {
                let directions: [String: Set<String>] = ["rotate": ["cw", "ccw"], "move": ["up", "down", "left", "right", "toward", "away", "up_left", "up_right", "down_left", "down_right"], "press": ["none"], "hold": ["none"], "align": ["none"]]
                try require(directions[arrow.type]?.contains(arrow.dir) == true)
            }
        }
        try require(!next.prompt.isEmpty && !next.reason.isEmpty)
        if !steps.isEmpty { try require(next.kind == .verify && !links.contains { $0.relation == .uncertain }) }
        if next.kind == .resolved {
            try require(request.resolutionConfirmed && request.history.contains { $0.outcome == .done } && steps.isEmpty)
        }
        if [.needsAnswer, .needsPhoto, .unresolved].contains(next.kind) { try require(steps.isEmpty) }
    }
}
