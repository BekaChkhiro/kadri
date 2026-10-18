#if DEBUG
import Foundation
import KadriCore

extension MockKadriAPI {
    static func checkPhotoScenario() -> MockCheckPhotoAPI { MockCheckPhotoAPI() }
}

/// Three steps → check photo → two steps → answer (or another photo) → complete.
final class MockCheckPhotoAPI: KadriAPI, @unchecked Sendable {
    static let prompt = "გადაიღე CPU-ს ბერკეტი ახლოდან"
    private let lock = NSLock()
    private var recordedImages: [Data?] = []
    private var recordedContexts: [SessionContext?] = []
    private var scans = 0
    var images: [Data?] { lock.withLock { recordedImages } }
    var contexts: [SessionContext?] { lock.withLock { recordedContexts } }
    var partsCount: Int { lock.withLock { scans } }

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        lock.withLock { scans += 1 }
        return MockKadriAPI.result
    }

    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        steps(object: object, parts: parts, instructions: instructions, image: nil, context: context, provider: nil)
    }

    func steps(object: String, parts: [Part], instructions: String, image: Data?, context: SessionContext?, provider: AIProvider?) -> AsyncThrowingStream<StepEvent, Error> {
        lock.withLock { recordedImages.append(image); recordedContexts.append(context) }
        let count = context?.checkPhotos ?? 0
        let steps: [Step]
        let next: StepsContinuation
        if count == 0 {
            steps = Array(MockKadriAPI.sampleSteps.prefix(3))
            next = .needsCheckPhoto(prompt: Self.prompt, reason: "ბერკეტის დაკეტვას ფოტოთი შევამოწმებ.")
        } else if count == 1 && context?.answers.isEmpty != false {
            steps = Array(MockKadriAPI.sampleSteps.suffix(2))
            next = .needsAnswer(question: "ბერკეტი დაკეტილია?", options: ["დიახ", "არა", "არ ვიცი", "ფოტოს გაჩვენებ"], allowOther: true, reason: nil)
        } else {
            steps = [MockKadriAPI.sampleSteps[0]]
            next = .complete
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: .milliseconds(200))
                    for step in steps { continuation.yield(.step(step)) }
                    continuation.yield(.done(nil, continuation: next))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
