import Foundation
import Observation

/// One problem, immutable submitted evidence, and an explicit history of user-reported outcomes.
@MainActor @Observable
public final class ProblemSessionModel {
    public enum Phase: Equatable, Sendable { case draft, loading, ready, error, unresolved, resolved }
    public static let maxPhotos = 5
    public static let maxHistory = 30
    public static let maxAnswers = 12
    public static let maxDescriptionLength = 1000
    public static let maxNoteLength = 300
    public static let maxAnswerLength = 500
    public var problem = ""
    public private(set) var photos: [ProblemPhoto] = []
    public private(set) var result: ProblemResult?
    public private(set) var history: [ProblemHistory] = []
    public private(set) var answers: [ProblemAnswer] = []
    public private(set) var currentStepIndex = 0
    public private(set) var phase: Phase = .draft
    public private(set) var errorMessage: String?
    public private(set) var hasSubmitted = false
    public let sessionId = UUID().uuidString
    @ObservationIgnored private let api: any KadriAPI
    @ObservationIgnored private let provider: AIProvider?
    @ObservationIgnored private var submittedIds: Set<String> = []
    @ObservationIgnored private var submittedProblem = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var work: Task<ProblemResult, Error>?
    @ObservationIgnored private var pendingConfirmation = false
    private var localContinuation: ProblemNext?

    public init(api: any KadriAPI, provider: AIProvider? = nil) { self.api = api; self.provider = provider }
    public var isLoading: Bool { phase == .loading }
    public var hasPendingPhotos: Bool { photos.contains { !submittedIds.contains($0.id) } }
    public var canAddPhoto: Bool { !isLoading && phase != .resolved && photos.count < Self.maxPhotos }
    public var currentStep: ProblemStep? {
        guard phase == .ready, let result, result.steps.indices.contains(currentStepIndex) else { return nil }
        return result.steps[currentStepIndex]
    }
    public var continuation: ProblemNext? {
        guard [.ready, .unresolved, .resolved].contains(phase), currentStep == nil else { return nil }
        return localContinuation ?? result?.next
    }
    public func canEditPhoto(id: String) -> Bool { !isLoading && !submittedIds.contains(id) && photos.contains { $0.id == id } }
    public func canRemovePhoto(id: String) -> Bool { canEditPhoto(id: id) }
    @discardableResult public func addPhoto(_ photo: ProblemPhoto) -> Bool {
        guard canAddPhoto, !photo.image.isEmpty, !photos.contains(where: { $0.id == photo.id }) else { return false }
        var bounded = photo
        bounded.note = Self.boundedText(photo.note, limit: Self.maxNoteLength)
        photos.append(bounded)
        pendingConfirmation = false
        return true
    }
    @discardableResult public func updatePhoto(id: String, note: String, role: ProblemPhoto.Role) -> Bool {
        guard canEditPhoto(id: id), let index = photos.firstIndex(where: { $0.id == id }) else { return false }
        photos[index].note = Self.boundedText(note, limit: Self.maxNoteLength); photos[index].role = role
        return true
    }
    @discardableResult public func removePhoto(id: String) -> Bool {
        guard canRemovePhoto(id: id) else { return false }
        photos.removeAll { $0.id == id }
        return true
    }
    public func submit() async {
        guard !isLoading && phase != .resolved else { return }
        let description = Self.boundedText(hasSubmitted ? submittedProblem : problem.trimmingCharacters(in: .whitespacesAndNewlines), limit: Self.maxDescriptionLength)
        if !hasSubmitted { problem = description }
        guard !description.isEmpty, !photos.isEmpty else {
            errorMessage = "აღწერე პრობლემა და დაამატე მინიმუმ ერთი ფოტო."
            return
        }
        submittedProblem = description
        let request = ProblemRequest(problem: description, photos: photos, history: history, answers: answers,
                                     previousComponents: result?.components ?? [], resolutionConfirmed: pendingConfirmation,
                                     provider: provider, sessionId: sessionId)
        generation += 1
        let expected = generation
        work?.cancel()
        errorMessage = nil; localContinuation = nil; phase = .loading
        let api = self.api
        let task = Task { try await api.problem(request) }
        work = task
        do {
            let response = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == expected else { return }
            try response.validate(for: request)
            result = response; currentStepIndex = 0
            hasSubmitted = true
            submittedIds.formUnion(request.photos.map(\.id))
            pendingConfirmation = false
            phase = response.next.kind == .resolved ? .resolved : .ready
            applyLimits()
        } catch {
            guard generation == expected else { return }
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                phase = result == nil ? .draft : .error
                errorMessage = result == nil ? nil : "ანალიზი შეწყდა. გასაგრძელებლად სცადე ხელახლა."
            } else {
                phase = .error
                errorMessage = (error as? LocalizedError)?.errorDescription ?? "პასუხი ვერ მივიღეთ. ფოტოები და შესრულებული ნაბიჯები შენახულია. სცადე ხელახლა."
            }
        }
        if generation == expected { work = nil }
    }
    public func retry() async { await submit() }
    public func cancel() {
        generation += 1; work?.cancel(); work = nil
        if isLoading {
            phase = result == nil ? .draft : .error
            errorMessage = result == nil ? nil : "ანალიზი შეწყდა. გასაგრძელებლად სცადე ხელახლა."
        }
    }
    public func markCurrentStep(outcome: ProblemHistory.Outcome, note: String = "") async {
        guard let step = currentStep, history.count < Self.maxHistory else { return }
        history.append(.init(stepId: step.id, title: step.title, photoId: step.photoId, outcome: outcome, note: Self.boundedText(note, limit: Self.maxNoteLength)))
        currentStepIndex += 1
        pendingConfirmation = false
        if outcome == .done { applyLimits() }
        else { await submit() }
    }
    public func answer(_ answer: String) async {
        guard !isLoading, currentStep == nil, let next = continuation,
              next.kind == .needsAnswer || next.kind == .verify,
              answers.count < Self.maxAnswers else { return }
        let value = Self.boundedText(answer.trimmingCharacters(in: .whitespacesAndNewlines), limit: Self.maxAnswerLength)
        guard !value.isEmpty else { return }
        answers.append(.init(question: next.prompt, answer: value))
        pendingConfirmation = false
        await submit()
    }
    public func confirmResolution() async {
        guard !isLoading, currentStep == nil, continuation?.kind == .verify,
              history.contains(where: { $0.outcome == .done }) else { return }
        pendingConfirmation = true
        await submit()
    }
    // Worker JSON-schema lengths count Unicode scalars, not Swift extended grapheme clusters.
    // Preserve whole visible characters while enforcing the same wire bound.
    private static func boundedText(_ value: String, limit: Int) -> String {
        var remaining = limit
        return String(value.prefix { character in
            let size = character.unicodeScalars.count
            guard size <= remaining else { return false }
            remaining -= size
            return true
        })
    }
    private func applyLimits() {
        guard phase != .resolved, let result else { return }
        let reason: String?
        if history.count >= Self.maxHistory && currentStepIndex < result.steps.count {
            reason = "მოქმედებების ლიმიტი ამოიწურა; პრობლემის მოგვარება არ დადასტურებულა."
        } else if currentStepIndex >= result.steps.count && result.next.kind == .needsPhoto && photos.count >= Self.maxPhotos {
            reason = "ამ სესიაში ხუთივე ფოტო უკვე დამატებულია; პრობლემის მოგვარება არ დადასტურებულა."
        } else if currentStepIndex >= result.steps.count && [.needsAnswer, .verify].contains(result.next.kind) && answers.count >= Self.maxAnswers {
            reason = "დაზუსტებების ლიმიტი ამოიწურა; პრობლემის მოგვარება არ დადასტურებულა."
        } else if result.next.kind == .unresolved { reason = result.next.reason }
        else { reason = nil }
        if let reason {
            phase = .unresolved
            localContinuation = .init(kind: .unresolved, prompt: "საჭიროა დამატებითი შემოწმება.", reason: reason)
        }
    }
}
