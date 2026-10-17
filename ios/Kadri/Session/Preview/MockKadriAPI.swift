#if DEBUG
import Foundation
import KadriCore

struct MockKadriAPI: KadriAPI {
    var scanDelay: Duration = .milliseconds(30)
    var stepDelay: Duration = .milliseconds(30)
    var initialStepDelay: Duration = .zero
    var failure: SessionError?

    func parts(keyframe: Data, instructions: String) async throws -> PartsResult {
        try await Task.sleep(for: scanDelay)
        if let failure { throw failure }
        return Self.result
    }

    func steps(object: String, parts: [Part], instructions: String) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: initialStepDelay)
                    for step in Self.sampleSteps {
                        continuation.yield(.step(step))
                        try await Task.sleep(for: stepDelay)
                    }
                    continuation.yield(.done(nil))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let result = PartsResult(object: "ნიჟარის სიფონი", parts: [
        Part(id: "p1", name: "ონკანი", box: [210, 210, 320, 335]),
        Part(id: "p2", name: "ქანჩი", box: [615, 245, 755, 380]),
        Part(id: "p3", name: "სიფონი", box: [300, 380, 670, 530]),
    ])
    static let sampleSteps = [
        Step(index: 1, title: "დაკეტე წყალი", text: "მოატრიალე ონკანი საათის ისრის მიმართულებით ბოლომდე. შემდეგ მეორეც დაკეტე.", focus: ["p1"], avoid: ["p2"],
             markers: [StepMarker(part: "p1", label: "ონკანი")],
             arrows: [StepArrow(part: "p1", type: "rotate", dir: "cw")],
             tip: "მეორე ონკანი მარცხნივაა"),
        Step(index: 2, title: "ჩადგი ვედრო სიფონის ქვეშ", text: "სიფონში წყალი დგას. ვედრო პირდაპირ მის ქვეშ დადგი.", focus: ["p3"],
             markers: [StepMarker(part: "p3", label: "ვედრო აქ")],
             arrows: [StepArrow(part: "p3", type: "move", dir: "down")],
             tools: ["ვედრო", "ტილო"],
             tip: "ვედრო პირდაპირ სიფონის ქვეშ დადგი."),
        Step(index: 3, title: "მოუშვი ქანჩი", text: "ხელით მოუშვი საათის ისრის საწინააღმდეგოდ.", focus: ["p2"],
             markers: [StepMarker(part: "p2", label: "ქანჩი")],
             arrows: [StepArrow(part: "p2", type: "rotate", dir: "ccw")],
             tools: ["ხელთათმანი"],
             warn: "პლასტმასისაა, ზედმეტ ძალას ნუ დაატან."),
        Step(index: 4, title: "შეამოწმე შეერთება", text: "გაწმინდე შეერთება და შეამოწმე რეზინის რგოლი. დაზიანებული რგოლი შეცვალე.", focus: ["p2"],
             markers: [StepMarker(part: "p2", label: "შეერთება")], tools: ["ტილო"],
             tip: "აწყობისას ქანჩი ხელით მოუჭირე."),
        Step(index: 5, title: "გადაამოწმე გაჟონვა", text: "ნელა გახსენი წყალი და დააკვირდი სიფონს. შეერთება მშრალი უნდა დარჩეს.", focus: ["p3"],
             markers: [StepMarker(part: "p3", label: "სიფონი")], tools: ["მშრალი ტილო"]),
    ]
}

@MainActor
enum SessionPreviewState: String, CaseIterable {
    case idle, describing, scanning, parts, waiting, streaming, steps, done, error

    func makeModel() -> SessionModel {
        SessionModel(api: MockKadriAPI(
            scanDelay: self == .scanning ? .seconds(3600) : .milliseconds(5),
            stepDelay: self == .streaming || self == .waiting ? .seconds(3600) : .milliseconds(5),
            initialStepDelay: self == .waiting ? .seconds(3600) : .zero,
            failure: self == .error ? .network : nil))
    }

    func prepare(_ model: SessionModel) async {
        guard self != .idle else { return }
        model.beginDescribing()
        model.updateText("ნიჟარა ჟონავს")
        guard self != .describing else { return }
        model.submit { Data() }
        guard self != .scanning else { return }
        for _ in 0..<200 {
            if case .scanning = model.phase { try? await Task.sleep(for: .milliseconds(5)) } else { break }
        }
        guard self != .parts && self != .error else { return }
        model.startSteps()
        guard self != .waiting else { return }
        for _ in 0..<200 {
            if case .steps(_, let steps, let streaming) = model.phase,
               self == .streaming ? !steps.isEmpty : !streaming { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if self == .done { model.finish() }
    }
}
#endif
