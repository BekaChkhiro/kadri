import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

/// Opt-in replay of recorded live responses. No provider calls and no physical repair.
@MainActor final class LiveProblemReplayTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/kadri-live-replay")
    private struct Manifest: Decodable {
        let reports: [String]
        let events: [Event]
        struct Event: Decodable { let kind: String; let text: String? }
    }
    private struct Report: Decodable {
        let response: ProblemResult
        let request: Request
        struct Request: Decodable {
            let problem: String
            let photos: [Photo]
            struct Photo: Decodable { let id: String; let path: String; let note: String; let role: ProblemPhoto.Role }
        }
    }
    func testRecordedRealPhotosThroughProblemFlow() async throws {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("Opt in by placing recorded live reports in /tmp/kadri-live-replay")
        }
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(Manifest.self, from: Data(contentsOf: manifestURL))
        let reports = try manifest.reports.map { try decoder.decode(Report.self, from: Data(contentsOf: directory.appendingPathComponent($0))) }
        let first = try XCTUnwrap(reports.first)
        let api = RecordedProblemAPI(results: reports.map(\.response))
        let model = ProblemSessionModel(api: api)
        model.problem = first.request.problem
        for photo in first.request.photos {
            XCTAssertTrue(model.addPhoto(.init(id: photo.id, image: try Data(contentsOf: URL(fileURLWithPath: photo.path)), note: photo.note, role: photo.role)))
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: PhotoProblemFlowView(model: model, isDemo: true).environment(\.photoOverlayReduceMotion, true))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host; window.makeKeyAndVisible()
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        for (index, event) in manifest.events.enumerated() {
            switch event.kind {
            case "submit": await model.submit()
            case "answer": await model.answer(try XCTUnwrap(event.text))
            case "done": await model.markCurrentStep(outcome: .done)
            case "unchanged": await model.markCurrentStep(outcome: .unchanged, note: event.text ?? "")
            default: XCTFail("Unknown replay event"); return
            }
            XCTAssertNotEqual(model.phase, .error, model.errorMessage ?? "")
            XCTAssertNotEqual(model.phase, .resolved, "No real repair outcome was confirmed")
            if let step = model.currentStep {
                for photo in model.photos {
                    let evidence = ProblemEvidenceView(photo: photo, result: model.result, step: step)
                    XCTAssertEqual(evidence.overlayStep != nil, photo.id == step.photoId && !step.componentIds.isEmpty)
                }
            }
            try await render(window, name: String(format: "%02d-%@", index, event.kind))
        }
        let remaining = await api.remaining
        XCTAssertEqual(remaining, 0, "All recorded live turns must be exercised")
    }
    private func render(_ window: UIWindow, name: String) async throws {
        try await Task.sleep(for: .milliseconds(650))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

private actor RecordedProblemAPI: KadriAPI {
    private var results: [ProblemResult]
    var remaining: Int { results.count }
    init(results: [ProblemResult]) { self.results = results }
    func problem(_ request: ProblemRequest) async throws -> ProblemResult {
        guard !results.isEmpty else { throw CancellationError() }
        let result = results.removeFirst()
        try result.validate(for: request)
        return result
    }
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult { throw CancellationError() }
    nonisolated func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: CancellationError()) }
    }
}
