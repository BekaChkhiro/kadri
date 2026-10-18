#if DEBUG && targetEnvironment(simulator)
import UIKit
import KadriCore

/// Plays the user's part for an end-to-end run (`--autopilot <dir>`): an outside driver drops photos into `dir`,
/// the autopilot submits them, walks every step and reports each round back as JSON files in the same folder.
///
/// In: `round-N.jpg|png` (round 1 also needs `comment.txt`), `answer-K.txt` for the session's K-th question.
/// Check photos: `check-N.request.json` out, `check-N.png` in; they keep the current round.
/// Out: `status.json` on every change, `question-K.json` when steps end with a question or a measurement,
/// `round-N.result.json` when a photo round ends (all of its answer turns included), `round-N.error.json`
/// on an error (it stops there), `done.json` once the session is finished. Every file is written atomically.
@MainActor
final class PhotoAutopilot {
    let session: PhotoSession
    let directory: URL
    let stepDelay: TimeInterval
    let pollInterval: TimeInterval

    /// Answering "I have no tool" to a measurement sends no unit.
    static let noToolAnswer = "არ მაქვს ხელსაწყო"

    private enum Stage: Equatable { case waitingForPhoto(Int), waitingForCheckPhoto(Int), waitingForAnswer(Int), running, stopped }
    private var stage: Stage = .waitingForPhoto(1)
    private var task: Task<Void, Never>?
    private var lastStatus: [String: AnyHashable]?
    private var stepIndexSeen = -1
    private var stepSeenAt = Date()
    private var roundStart = Date()
    private var scanMs: Int?
    private var firstStepMs: Int?
    private var stepsDoneMs: Int?
    /// Set when an answer is sent; the first step of that turn appends to `turnFirstStepMs`.
    private var turnStart: Date?
    private var turnFirstStepMs: [Int] = []
    /// Steps cost of this photo's finished answer turns; `model.usage` only holds the latest stream's.
    private var turnCosts: [Double] = []
    private var questions = 0
    private var photoAnswerCostRecorded = false

    init(session: PhotoSession, directory: URL, stepDelay: TimeInterval = 3.5, pollInterval: TimeInterval = 0.5) {
        self.session = session
        self.directory = directory
        self.stepDelay = stepDelay
        self.pollInterval = pollInterval
    }

    /// `--autopilot <dir> [--autopilot-step-delay <s>]`; nil without `--autopilot`.
    static func fromArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments,
                              session: PhotoSession) -> PhotoAutopilot? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  !arguments[index + 1].hasPrefix("--") else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--autopilot") else { return nil }
        let delay = value("--autopilot-step-delay").flatMap(TimeInterval.init) ?? 3.5
        return PhotoAutopilot(session: session, directory: URL(fileURLWithPath: path), stepDelay: max(0, delay))
    }

    var isStopped: Bool { stage == .stopped }

    func start() {
        guard task == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        task = Task { [weak self] in
            while let self, !Task.isCancelled, self.stage != .stopped {
                self.tick()
                try? await Task.sleep(for: .seconds(self.pollInterval))
            }
        }
    }

    func stop() {
        task?.cancel(); task = nil
    }

    // MARK: - Loop

    func tick() {
        let model = session.model
        // Without PhotoFlowView (unit tests) nobody else starts the steps once parts arrive; the call is idempotent.
        if case .parts = model.phase { session.phaseChanged() }
        switch stage {
        case .stopped: return
        case .waitingForPhoto(let number): takePhoto(number)
        case .waitingForCheckPhoto(let number): takeCheckPhoto(number)
        case .waitingForAnswer(let number): takeAnswer(number, model)
        case .running: drive(model)
        }
        writeStatus()
    }

    private func takePhoto(_ number: Int) {
        guard let image = photo(number) else { return }
        if number == 1 {
            guard let comment = try? String(contentsOf: file("comment.txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !comment.isEmpty else { return }
            session.select(image)
            // Same choice the describe panel would send (UserDefaults "photoAIProvider").
            let provider = UserDefaults.standard.string(forKey: "photoAIProvider").flatMap(AIProvider.init(rawValue:)) ?? .astra
            session.submit(comment, provider: provider)
        } else {
            guard session.model.canContinueWithPhoto else { return }
            session.continueWithPhoto(image)
        }
        roundStart = Date(); scanMs = nil; firstStepMs = nil; stepsDoneMs = nil
        turnStart = nil; turnFirstStepMs = []; turnCosts = []
        stage = .running
    }

    private func takeCheckPhoto(_ number: Int) {
        guard session.model.canContinueWithCheckPhoto,
              let image = UIImage(contentsOfFile: file("check-\(number).png").path) else { return }
        session.continueWithCheckPhoto(image)
        turnStart = Date()
        stage = .running
    }

    private func takeAnswer(_ number: Int, _ model: SessionModel) {
        guard let raw = try? String(contentsOf: file("answer-\(number).txt"), encoding: .utf8) else { return }
        let text = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
        guard !text.isEmpty, model.canContinueWithAnswer else { return }
        var unit: String?
        if case .needsMeasurement(_, let value, _, _, _, _) = model.continuation, text != Self.noToolAnswer { unit = value }
        let before = model.answers.count
        model.continueWithAnswer(text, unit: unit)
        if model.canContinueWithCheckPhoto {
            photoAnswerCostRecorded = true
            stage = .running
            return
        }
        guard model.answers.count > before else { return }
        turnStart = Date()
        stage = .running
    }

    private func photo(_ number: Int) -> UIImage? {
        for ext in ["jpg", "jpeg", "png"] {
            let url = file("round-\(number).\(ext)")
            if FileManager.default.fileExists(atPath: url.path), let image = UIImage(contentsOfFile: url.path) { return image }
        }
        return nil
    }

    private func drive(_ model: SessionModel) {
        let round = model.round
        switch model.phase {
        case .error(let error, _):
            write(["round": round, "code": Self.code(error), "message": error.localizedDescription],
                  to: "round-\(round).error.json")
            stage = .stopped
        case .parts:
            if scanMs == nil { scanMs = elapsed() }
        case .steps(let result, let steps, let streaming):
            if scanMs == nil { scanMs = elapsed() }
            if firstStepMs == nil, !steps.isEmpty { firstStepMs = elapsed() }
            if let turnStart, !steps.isEmpty {
                turnFirstStepMs.append(Int(Date().timeIntervalSince(turnStart) * 1000))
                self.turnStart = nil
            }
            if stepsDoneMs == nil, !streaming { stepsDoneMs = elapsed() }
            if model.currentStepIndex != stepIndexSeen { stepIndexSeen = model.currentStepIndex; stepSeenAt = Date() }
            guard Date().timeIntervalSince(stepSeenAt) >= stepDelay else { return }
            if model.currentStepIndex < model.allSteps.count - 1 {
                model.next()
            } else if !streaming {
                if model.canContinueWithAnswer, var question = questionJSON(model) {
                    questions += 1
                    let number = questions
                    question["costUsd"] = model.usage?.costUsd ?? NSNull()
                    turnCosts.append(model.usage?.costUsd ?? 0)
                    write(question, to: "question-\(number).json")
                    stage = .waitingForAnswer(number)
                    return
                }
                if model.canContinueWithCheckPhoto {
                    write(resultJSON(model, result: result), to: "check-\(model.checkPhotos + 1).request.json")
                    if !photoAnswerCostRecorded { turnCosts.append(model.usage?.costUsd ?? 0) }
                    photoAnswerCostRecorded = false
                    stage = .waitingForCheckPhoto(model.checkPhotos + 1)
                    return
                }
                write(resultJSON(model, result: result), to: "round-\(round).result.json")
                if model.canContinueWithPhoto {
                    stage = .waitingForPhoto(round + 1)
                } else {
                    // Also reached at the answer limit: the session ends as complete.
                    let cause = model.foundCause, summary = model.completionSummary
                    model.finish()
                    session.phaseChanged()
                    write(["rounds": round, "checkPhotos": model.checkPhotos, "steps": model.allSteps.count, "answers": model.answers.count,
                           "cause": cause ?? NSNull(), "summary": summary ?? NSNull()], to: "done.json")
                    stage = .stopped
                }
            }
        default: break
        }
    }

    private func elapsed() -> Int { Int(Date().timeIntervalSince(roundStart) * 1000) }

    // MARK: - Files

    private func questionJSON(_ model: SessionModel) -> [String: Any]? {
        var json: [String: Any] = ["round": model.round, "turn": questions + 1, "stepsSoFar": model.allSteps.count,
                                   "stepTitles": model.allSteps.map(\.title)]
        switch model.continuation {
        case .needsAnswer(let question, let options, let allowOther, let reason):
            json.merge(["kind": "needs_answer", "question": question, "options": options, "allowOther": allowOther,
                        "unit": NSNull(), "min": NSNull(), "max": NSNull(), "how": NSNull(),
                        "reason": reason ?? NSNull()]) { $1 }
        case .needsMeasurement(let question, let unit, let min, let max, let how, let reason):
            json.merge(["kind": "needs_measurement", "question": question, "options": [String](), "allowOther": false,
                        "unit": unit, "min": min ?? NSNull(), "max": max ?? NSNull(), "how": how,
                        "reason": reason ?? NSNull()]) { $1 }
        default: return nil
        }
        return json
    }

    private static func kind(_ continuation: StepsContinuation?) -> String {
        switch continuation {
        case .needsPhoto: "needs_photo"
        case .needsCheckPhoto: "needs_check_photo"
        case .needsAnswer: "needs_answer"
        case .needsMeasurement: "needs_measurement"
        default: "complete"
        }
    }

    private func resultJSON(_ model: SessionModel, result: PartsResult) -> [String: Any] {
        // Every step of this photo, across its answer turns; earlier photos' steps come first in `allSteps`.
        let offset = model.completedRounds.reduce(0) { $0 + $1.steps.count }
        let steps: [[String: Any]] = model.allSteps.enumerated().dropFirst(offset).map { index, step in
            ["index": index + 1, "title": step.title, "text": step.text, "focus": step.focus,
             "icon": step.icon ?? NSNull(), "warn": step.warn ?? NSNull(), "tip": step.tip ?? NSNull()]
        }
        var continuation: [String: Any] = ["kind": "complete", "cause": NSNull(), "summary": NSNull()]
        switch model.continuation {
        case .needsPhoto(let prompt, let reason):
            continuation = ["kind": "needs_photo", "prompt": prompt, "reason": reason]
        case .needsCheckPhoto(let prompt, let reason):
            // A check photo goes straight to /ai/steps; the loop treats it like needs_photo (see e2e_codex_loop.py).
            continuation = ["kind": "needs_check_photo", "prompt": prompt, "reason": reason]
        case .complete(let cause, let summary):
            continuation = ["kind": "complete", "cause": cause ?? NSNull(), "summary": summary ?? NSNull()]
        case .needsAnswer, .needsMeasurement:
            // Only when no more answers are allowed; the session ends here.
            continuation["answerLimitReached"] = true
        case nil: break
        }
        // Each finished turn was answered by the answer appended right after it.
        let answerTurns = model.completedTurns.filter {
            switch $0.continuation {
            case .needsAnswer, .needsMeasurement: true
            default: false
            }
        }
        let answers = model.answers.suffix(answerTurns.count)
        let turns: [[String: Any]] = zip(answerTurns, answers).map { turn, answer in
            ["kind": Self.kind(turn.continuation), "question": answer.question, "answer": answer.answer,
             "unit": answer.unit ?? NSNull()]
        }
        let costs = turnCosts + (photoAnswerCostRecorded ? [] : [model.usage?.costUsd].compactMap { $0 })
        let cost: Double? = costs.isEmpty ? nil : costs.reduce(0, +)
        return [
            "round": model.round,
            "checkPhotos": model.checkPhotos,
            "object": result.object,
            "parts": result.parts.map { ["id": $0.id, "name": $0.name, "box": $0.box] as [String: Any] },
            "steps": steps,
            "continuation": continuation,
            "turns": turns,
            "latestCostUsd": model.usage?.costUsd ?? NSNull(),
            "costUsd": cost.map { $0 as Any } ?? NSNull(),
            "timings": ["scanMs": scanMs ?? NSNull(), "firstStepMs": firstStepMs ?? NSNull(),
                        "stepsDoneMs": stepsDoneMs ?? NSNull(), "turnFirstStepMs": turnFirstStepMs] as [String: Any],
        ]
    }

    private func writeStatus() {
        let model = session.model
        var streaming = false
        let phase: String
        switch model.phase {
        case .idle, .describing: phase = "describing"
        case .scanning: phase = "scanning"
        case .parts: phase = "parts"
        case .steps(_, _, let isStreaming): phase = "steps"; streaming = isStreaming
        case .done: phase = "done"
        case .error: phase = "error"
        }
        var status: [String: AnyHashable] = [
            "phase": phase, "round": model.round, "checkPhotos": model.checkPhotos, "stepIndex": model.currentStepIndex + 1,
            "stepsCount": model.allSteps.count, "streaming": streaming,
        ]
        if case .waitingForPhoto(let number) = stage { status["waitingForPhoto"] = number }
        if case .waitingForCheckPhoto(let number) = stage {
            status["waitingForCheckPhoto"] = number
            status["kind"] = "needs_check_photo"
            if case .needsCheckPhoto(let prompt, let reason) = model.continuation {
                status["prompt"] = prompt; status["reason"] = reason
            }
        }
        if case .waitingForAnswer(let number) = stage { status["waitingForAnswer"] = number }
        guard status != lastStatus else { return }
        lastStatus = status
        var json: [String: Any] = status
        json["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        write(json, to: "status.json")
    }

    private func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    private func write(_ object: [String: Any], to name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        let target = file(name)
        let temporary = file(".\(name).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temporary)
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private static func code(_ error: SessionError) -> String {
        switch error {
        case .network: "network"
        case .timeout: "timeout"
        case .server(let code, _): code
        case .unauthorized: "unauthorized"
        case .cancelled: "cancelled"
        case .noParts: "no_parts"
        }
    }
}
#endif
