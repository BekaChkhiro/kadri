#if DEBUG
import SwiftUI
import KadriCore

@MainActor enum PhotoProblemDemo {
    static func model() -> ProblemSessionModel {
        let model = ProblemSessionModel(api: ProblemDemoAPI())
        model.problem = "ნიჟარის ქვეშ წყლის წვეთებია. საიდან მოდის?"
        guard let source = PhotoArrowDemoScene.image(0), let cg = source.cgImage,
              let full = try? ProblemPhotoImport.jpeg(from: source) else { return model }
        _ = model.addPhoto(.init(id: "overall", image: full, note: "ნიჟარის ქვედა ნაწილი", role: .overview))
        // The second fixture is an explicitly labelled crop of the same scene; coordinates match that crop.
        let crop = CGRect(x: CGFloat(cg.width) * 0.5, y: CGFloat(cg.height) * 0.15,
                          width: CGFloat(cg.width) * 0.4, height: CGFloat(cg.height) * 0.4).integral
        if let detail = cg.cropping(to: crop), let data = try? ProblemPhotoImport.jpeg(from: UIImage(cgImage: detail)) {
            _ = model.addPhoto(.init(id: "detail", image: data, note: "იმავე ფოტოს გადიდებული დეტალი · დემო", role: .detail))
        }
        return model
    }
}

struct ProblemDemoAPI: KadriAPI {
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult { throw CancellationError() }
    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
    func problem(_ request: ProblemRequest) async throws -> ProblemResult {
        try await Task.sleep(for: .milliseconds(450))
        let components: [ProblemComponent] = [.init(id: "joint", name: "შეერთების ქანჩი", views: request.photos.compactMap {
            switch $0.id {
            case "overall": .init(photoId: $0.id, box: [620, 250, 750, 385])
            case "detail": .init(photoId: $0.id, box: [300, 250, 625, 588])
            default: nil
            }
        })]
        let observations = request.photos.map {
            ProblemObservation(photoId: $0.id, detail: $0.id == "overall" ? "საერთო ხედი: ნიჟარის ქვედა შეერთება." : ($0.id == "detail" ? "იმავე შეერთების დეტალი. წყაროს დასადგენად საჭიროა შემოწმება." : "დემოში დამატებული ფოტოს რეალური ანალიზი არ ხდება."), relevance: ["overall", "detail"].contains($0.id) ? "relevant" : "uncertain")
        }
        let next: ProblemNext
        var steps: [ProblemStep] = []
        if request.resolutionConfirmed {
            next = .init(kind: .resolved, prompt: "შენ დაადასტურე, რომ პრობლემა მოგვარდა.", reason: "დემო დასრულდა მომხმარებლის დადასტურებით; AI-ს ფოტო არ შეუმოწმებია.")
        } else if request.answers.isEmpty {
            next = .init(kind: .needsAnswer, prompt: "წვეთები ამ შეერთებაზე ჩნდება თუ ზემოდან ჩამოდის?", reason: "სხვადასხვა ხედის დაკავშირება გაჟონვის მიზეზს თავისთავად არ ადასტურებს.")
        } else if request.history.contains(where: { $0.outcome != .done }) {
            next = .init(kind: .unresolved, prompt: "საჭიროა დამატებითი შემოწმება.", reason: "ეს დემო აქ ჩერდება; წარუმატებელი მოქმედება დასრულებად არ ჩაითვალა.")
        } else if request.history.isEmpty {
            if request.photos.contains(where: { $0.id == "overall" }) {
                steps.append(.init(id: "locate", title: "იპოვე მონიშნული შეერთება", text: "საერთო ხედზე იპოვე ქანჩი. ჯერ არაფერი მოატრიალო ან მოხსნა.", photoId: "overall", componentIds: ["joint"], arrow: .init(type: "align", dir: "none")))
            }
            if request.photos.contains(where: { $0.id == "detail" }) {
                steps.append(.init(id: "inspect", title: "დააკვირდი შეერთების ზედა კიდეს", text: "დეტალის ფოტოზე მონიშნულია იგივე ქანჩი. შეამოწმე, საიდან ჩნდება პირველი წვეთი და ჩაიწერე შედეგი.", photoId: "detail", componentIds: ["joint"], arrow: .init(type: "move", dir: "up")))
            }
            next = .init(kind: .verify, prompt: "პრობლემა მოგვარდა?", reason: "შემოწმების შესრულება ჯერ არ ნიშნავს, რომ გაჟონვა შეწყდა. აღწერე რეალური შედეგი.")
        } else {
            next = .init(kind: .unresolved, prompt: "შედეგი ჯერ არ დადასტურებულა.", reason: "დემო არ იგონებს ახალ დიაგნოზს. რეალური პასუხისთვის საჭიროა სერვერის ანალიზი.")
        }
        return .init(summary: "ორი ხედი ერთ შეერთებას აჩვენებს. გაჟონვის მიზეზი ჯერ დასადგენია.", observations: observations, components: components, links: [], steps: steps, next: next)
    }
}
#endif
