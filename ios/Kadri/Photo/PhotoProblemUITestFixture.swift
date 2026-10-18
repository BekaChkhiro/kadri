#if DEBUG
import UIKit
import KadriCore

/// An explicit launch flag selects this local fixture; normal app sessions always retain their real API.
@MainActor
enum PhotoProblemUITestFixture {
    static func makeSession() -> PhotoSession {
        let api = PhotoProblemUITestAPI(failFirst: ProcessInfo.processInfo.arguments.contains("--ui-test-problem-failure"))
        let session = PhotoSession(api: api)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 160), format: format)
        func image(_ color: UIColor) -> UIImage {
            renderer.image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 240, height: 160))
            }
        }
        session.select(image(.systemBlue))
        session.addDraftPhoto(image(.systemOrange))
        session.model.updateText("სატესტო პრობლემა ორ ფოტოზე")
        return session
    }
}

private actor PhotoProblemUITestAPI: KadriAPI {
    private var requestCount = 0
    private let failFirst: Bool
    init(failFirst: Bool) { self.failFirst = failFirst }

    func problem(_ request: ProblemRequest) async throws -> ProblemResult {
        requestCount += 1
        if failFirst && requestCount == 1 { throw URLError(.notConnectedToInternet) }
        return .init(summary: "ორი ფოტო ერთ პრობლემაშია მიღებული", observations: request.photos.map {
            .init(photoId: $0.id, detail: "სატესტო ხედი", relevance: "uncertain")
        }, components: [], links: [], steps: [],
        next: .init(kind: .needsAnswer, prompt: "სატესტო კითხვა \(requestCount)", reason: "ფოტოების კავშირი დასაზუსტებელია"))
    }

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        throw SessionError.server(code: "unexpected_single_photo", message: "საჭიროა ორივე ფოტო")
    }
    nonisolated func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
#endif
