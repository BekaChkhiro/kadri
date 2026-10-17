#if DEBUG && targetEnvironment(simulator)
import UIKit
import KadriCore

/// Plays the user's part for an end-to-end run (`--autopilot <dir>`): an outside driver drops photos into `dir`,
/// the autopilot submits them, walks every step and reports each round back as JSON files in the same folder.
///
/// In: `round-N.jpg|png` (round 1 also needs `comment.txt`). Out: `status.json` on every change,
/// `round-N.result.json` when a round's steps end, `round-N.error.json` on an error (it stops there),
/// `done.json` once the session is finished. Every file is written atomically.
@MainActor
final class PhotoAutopilot {
    let session: PhotoSession
    let directory: URL
    let stepDelay: TimeInterval
    let pollInterval: TimeInterval

    private enum Stage: Equatable { case waitingForPhoto(Int), running, stopped }
    private var stage: Stage = .waitingForPhoto(1)
    private var task: Task<Void, Never>?
    private var lastStatus: [String: AnyHashable]?
    private var stepIndexSeen = -1
    private var stepSeenAt = Date()
    private var roundStart = Date()
    private var scanMs: Int?
    private var firstStepMs: Int?
    private var stepsDoneMs: Int?

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
            session.submit(comment)
        } else {
            guard session.model.canContinueWithPhoto else { return }
            session.continueWithPhoto(image)
        }
        roundStart = Date(); scanMs = nil; firstStepMs = nil; stepsDoneMs = nil
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
            if stepsDoneMs == nil, !streaming { stepsDoneMs = elapsed() }
            if model.currentStepIndex != stepIndexSeen { stepIndexSeen = model.currentStepIndex; stepSeenAt = Date() }
            guard Date().timeIntervalSince(stepSeenAt) >= stepDelay else { return }
            if model.currentStepIndex < model.allSteps.count - 1 {
                model.next()
            } else if !streaming {
                write(resultJSON(model, result: result), to: "round-\(round).result.json")
                if model.canContinueWithPhoto {
                    stage = .waitingForPhoto(round + 1)
                } else {
                    model.finish()
                    session.phaseChanged()
                    write(["rounds": round, "steps": model.allSteps.count], to: "done.json")
                    stage = .stopped
                }
            }
        default: break
        }
    }

    private func elapsed() -> Int { Int(Date().timeIntervalSince(roundStart) * 1000) }

    // MARK: - Files

    private func resultJSON(_ model: SessionModel, result: PartsResult) -> [String: Any] {
        let offset = model.stepOffset
        let steps: [[String: Any]] = model.allSteps.enumerated().dropFirst(offset).map { index, step in
            ["index": index + 1, "title": step.title, "text": step.text, "focus": step.focus,
             "icon": step.icon ?? NSNull(), "warn": step.warn ?? NSNull(), "tip": step.tip ?? NSNull()]
        }
        var continuation: [String: Any] = ["kind": "complete"]
        if case .needsPhoto(let prompt, let reason) = model.continuation {
            continuation = ["kind": "needs_photo", "prompt": prompt, "reason": reason]
        }
        return [
            "round": model.round,
            "object": result.object,
            "parts": result.parts.map { ["id": $0.id, "name": $0.name, "box": $0.box] as [String: Any] },
            "steps": steps,
            "continuation": continuation,
            "costUsd": model.usage?.costUsd ?? NSNull(),
            "timings": ["scanMs": scanMs ?? NSNull(), "firstStepMs": firstStepMs ?? NSNull(),
                        "stepsDoneMs": stepsDoneMs ?? NSNull()] as [String: Any],
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
            "phase": phase, "round": model.round, "stepIndex": model.currentStepIndex + 1,
            "stepsCount": model.allSteps.count, "streaming": streaming,
        ]
        if case .waitingForPhoto(let number) = stage { status["waitingForPhoto"] = number }
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
