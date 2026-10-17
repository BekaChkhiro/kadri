#if DEBUG
import Foundation
import KadriCore

struct MockKadriAPI: KadriAPI {
    var scanDelay: Duration = .milliseconds(30)
    var stepDelay: Duration = .milliseconds(30)
    var initialStepDelay: Duration = .zero
    var failure: SessionError?
    /// Two photos: the first stops after three steps and asks for the removed siphon, the second finishes.
    var multiPhoto = false

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        try await Task.sleep(for: scanDelay)
        if let failure { throw failure }
        return multiPhoto && context?.round == 2 ? Self.round2Result : Self.result
    }

    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        let (steps, next): ([Step], StepsContinuation) = switch (multiPhoto, context?.round) {
        case (false, _): (Self.sampleSteps, .complete)
        case (true, nil): (Array(Self.sampleSteps.prefix(3)), .needsPhoto(prompt: Self.round2Prompt, reason: "შუასადების მდგომარეობა ამ ფოტოზე არ ჩანს."))
        case (true, _): (Self.round2Steps, .complete)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Task.sleep(for: initialStepDelay)
                    for step in steps {
                        continuation.yield(.step(step))
                        try await Task.sleep(for: stepDelay)
                    }
                    continuation.yield(.done(nil, continuation: next))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static let result = PartsResult(object: "ნიჟარის სიფონი", parts: [
        Part(id: "p1", name: "ონკანი", box: [210, 65, 320, 252]),
        Part(id: "p2", name: "ქანჩი", box: [615, 117, 755, 320]),
        Part(id: "p3", name: "სიფონი", box: [300, 320, 670, 545]),
    ])
    static let sampleSteps = [
        Step(index: 1, title: "დაკეტე წყალი", text: "მოატრიალე ონკანი საათის ისრის მიმართულებით ბოლომდე. შემდეგ მეორეც დაკეტე.", focus: ["p1"], avoid: ["p2"],
             markers: [StepMarker(part: "p1", label: "ონკანი")],
             arrows: [StepArrow(part: "p1", type: "rotate", dir: "cw")],
             tip: "მეორე ონკანი მარცხნივაა", icon: "rotate_cw"),
        Step(index: 2, title: "ჩადგი ვედრო სიფონის ქვეშ", text: "სიფონში წყალი დგას. ვედრო პირდაპირ მის ქვეშ დადგი.", focus: ["p3"],
             markers: [StepMarker(part: "p3", label: "ვედრო აქ")],
             arrows: [StepArrow(part: "p3", type: "move", dir: "down")],
             tools: ["ვედრო", "ტილო"],
             tip: "ვედრო პირდაპირ სიფონის ქვეშ დადგი.", icon: "place",
             toolItems: [StepTool(label: "ვედრო", icon: "bucket"), StepTool(label: "ტილო", icon: "cloth")]),
        Step(index: 3, title: "მოუშვი ქანჩი", text: "ხელით მოუშვი საათის ისრის საწინააღმდეგოდ.", focus: ["p2"],
             markers: [StepMarker(part: "p2", label: "ქანჩი")],
             arrows: [StepArrow(part: "p2", type: "rotate", dir: "ccw")],
             tools: ["ხელთათმანი"],
             warn: "პლასტმასისაა, ზედმეტ ძალას ნუ დაატან.", icon: "unscrew",
             toolItems: [StepTool(label: "ხელთათმანი", icon: "gloves")]),
        Step(index: 4, title: "შეამოწმე შეერთება", text: "გაწმინდე შეერთება და შეამოწმე რეზინის რგოლი. დაზიანებული რგოლი შეცვალე.", focus: ["p2"],
             markers: [StepMarker(part: "p2", label: "შეერთება")], tools: ["ტილო"],
             tip: "აწყობისას ქანჩი ხელით მოუჭირე.", icon: "clean",
             toolItems: [StepTool(label: "ტილო", icon: "cloth")]),
        Step(index: 5, title: "გადაამოწმე გაჟონვა", text: "ნელა გახსენი წყალი და დააკვირდი სიფონს. შეერთება მშრალი უნდა დარჩეს.", focus: ["p3"],
             markers: [StepMarker(part: "p3", label: "სიფონი")], tools: ["მშრალი ტილო"], icon: "check",
             toolItems: [StepTool(label: "მშრალი ტილო", icon: "cloth")]),
    ]

    static let round2Prompt = "გადაიღე მოხსნილი სიფონის შიგნითა მხარე ახლოდან"
    static let round2Result = PartsResult(object: "მოხსნილი სიფონი", parts: [
        Part(id: "p1", name: "შუასადები", box: [380, 380, 620, 590]),
        Part(id: "p2", name: "ხრახნიანი შეერთება", box: [250, 200, 450, 440]),
        Part(id: "p3", name: "სიფონის მილი", box: [300, 590, 700, 980]),
    ])
    static let round2Steps = [
        Step(index: 1, title: "შეამოწმე შუასადები", text: "ამოიღე შუასადები და დაათვალიერე. გაბზარული ან გაბრტყელებული შეცვალე.", focus: ["p1"],
             markers: [StepMarker(part: "p1", label: "შუასადები")], icon: "check"),
        Step(index: 2, title: "დააბრუნე სიფონი", text: "შუასადები ადგილზე ჩადე და შეერთება ხელით მოუჭირე.", focus: ["p2", "p3"],
             markers: [StepMarker(part: "p2", label: "შეერთება")],
             arrows: [StepArrow(part: "p2", type: "rotate", dir: "cw")],
             warn: "ზედმეტად ნუ მოუჭერ — პლასტმასი გასკდება.", icon: "rotate_cw"),
        Step(index: 3, title: "გადაამოწმე გაჟონვა", text: "ნელა გახსენი წყალი და დააკვირდი შეერთებას. მშრალი უნდა დარჩეს.", focus: ["p3"],
             markers: [StepMarker(part: "p3", label: "სიფონი")], tools: ["მშრალი ტილო"], icon: "check",
             toolItems: [StepTool(label: "მშრალი ტილო", icon: "cloth")]),
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
