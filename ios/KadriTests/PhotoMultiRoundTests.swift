import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class PhotoMultiRoundTests: XCTestCase {
    func testLastStepAsksForAPhotoOnlyOnceTheRoundEnds() {
        XCTAssertEqual(PhotoStepPresentation.state(index: 2, count: 3, streaming: false, needsPhoto: true), .newPhoto)
        XCTAssertEqual(PhotoStepPresentation.state(index: 2, count: 3, streaming: true, needsPhoto: true), .preparing)
        XCTAssertEqual(PhotoStepPresentation.state(index: 1, count: 3, streaming: false, needsPhoto: true), .next)
        XCTAssertEqual(PhotoStepPresentation.state(index: 2, count: 3, streaming: false), .finish)
        XCTAssertEqual(PhotoStepPresentation.state(index: 0, count: 0, streaming: false, needsPhoto: true), .preparing)
        XCTAssertFalse(PhotoStepPresentation.newPhoto.disabled)
        XCTAssertEqual(PhotoStepPresentation.newPhoto.title, "ახალი ფოტო")
    }

    func testTwoPhotoSessionKeepsEachRoundsPhoto() async throws {
        let session = PhotoSession(api: MockKadriAPI(scanDelay: .milliseconds(5), stepDelay: .milliseconds(5), multiPhoto: true))
        let model = session.model
        session.selectDemo()
        session.submit("ნიჟარა ჟონავს")
        try await waitForFinishedSteps(session)
        XCTAssertEqual(model.continuation, .needsPhoto(prompt: MockKadriAPI.round2Prompt, reason: "შუასადების მდგომარეობა ამ ფოტოზე არ ჩანს."))
        XCTAssertTrue(model.canContinueWithPhoto)
        model.next(); model.next()
        XCTAssertEqual(model.currentStepIndex, 2)
        let firstImage = try XCTUnwrap(session.image)
        XCTAssertEqual(firstImage.size, CGSize(width: 1024, height: 1024))
        let firstMeshes = session.meshes.map(\.id)

        session.continueWithDemo()
        guard case .scanning = model.phase else { return XCTFail("expected scanning, got \(model.phase)") }
        XCTAssertEqual(model.round, 2)
        XCTAssertFalse(session.image === firstImage)
        try await waitForFinishedSteps(session)
        XCTAssertEqual(model.allSteps.count, 6)
        XCTAssertEqual(model.currentStepIndex, 3)
        XCTAssertEqual(model.displayedRound, 2)
        XCTAssertEqual(model.continuation, .complete)
        XCTAssertFalse(model.canContinueWithPhoto)
        XCTAssertTrue(try XCTUnwrap(session.displayedImage) === session.image)
        XCTAssertEqual(model.displayedResult, MockKadriAPI.round2Result)

        model.previous()
        XCTAssertEqual(model.displayedRound, 1)
        XCTAssertTrue(try XCTUnwrap(session.displayedImage) === firstImage)
        XCTAssertEqual(session.displayedMeshes.map(\.id), firstMeshes)
        XCTAssertEqual(model.displayedResult, MockKadriAPI.result)
        model.previous(); model.previous()
        XCTAssertEqual(model.currentStepIndex, 0)
        XCTAssertEqual(model.displayedRound, 1)

        for _ in 0..<5 { model.next() }
        XCTAssertEqual(model.displayedRound, 2)
        model.finish()
        session.phaseChanged()
        guard case .done = model.phase else { return XCTFail("expected done, got \(model.phase)") }
        XCTAssertEqual(model.allSteps.count, 6)
    }

    func testCancellingTheNextPhotoRestoresThePreviousOne() async throws {
        let session = PhotoSession(api: MockKadriAPI(scanDelay: .milliseconds(5), stepDelay: .milliseconds(5), multiPhoto: true))
        session.selectDemo()
        session.submit("ნიჟარა ჟონავს")
        try await waitForFinishedSteps(session)
        let firstImage = try XCTUnwrap(session.image)
        session.continueWithDemo()
        session.phaseChanged()
        session.model.cancel()
        session.phaseChanged()
        XCTAssertEqual(session.model.round, 1)
        XCTAssertTrue(session.model.canContinueWithPhoto)
        XCTAssertTrue(session.image === firstImage)
        XCTAssertTrue(session.displayedImage === firstImage)
    }

    func testRoundTwoFailureKeepsThePreviousSteps() async throws {
        let session = PhotoSession(api: FailingRoundTwoAPI())
        let model = session.model
        let host = UIHostingController(rootView: PhotoFlowView(session: session).environment(\.meshWrapReduceMotion, true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }

        session.selectDemo()
        session.submit("ნიჟარა ჟონავს")
        try await waitForFinishedSteps(session)
        let firstImage = try XCTUnwrap(session.image)
        let firstSteps = model.allSteps
        session.continueWithDemo()
        try await poll(2, "round 2 scan header") { Self.element(in: host.view, label: "ფოტო 2") != nil }

        try await poll(5, "round 2 error") {
            if case .error = model.phase { return true }
            return false
        }
        XCTAssertEqual(model.allSteps, firstSteps)
        try await poll(2, "error screen") { Self.element(in: host.view, label: "ფოტო 2 ვერ დამუშავდა") != nil }
        XCTAssertNotNil(Self.element(in: host.view, label: "წინა \(firstSteps.count) ნაბიჯი შენახულია."))
        XCTAssertNotNil(Self.element(in: host.view, label: "თავიდან"))
        let back = try XCTUnwrap(Self.element(in: host.view, label: "წინა ნაბიჯებზე"))

        XCTAssertTrue(back.accessibilityActivate())
        try await poll(2, "round 1 steps") { session.phaseChanged(); return model.round == 1 && session.image === firstImage }
        XCTAssertEqual(model.allSteps, firstSteps)
        XCTAssertTrue(model.canContinueWithPhoto)
    }

    func testScreens() async throws {
        let directory = URL(fileURLWithPath: "/tmp/kadri-photo-shots-square")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = PhotoSession(api: MockKadriAPI(scanDelay: .seconds(3), stepDelay: .milliseconds(40), multiPhoto: true))
        let model = session.model
        let host = UIHostingController(rootView: PhotoFlowView(session: session).environment(\.meshWrapReduceMotion, true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousWindow?.makeKeyAndVisible() }

        try await shot("start", window, directory)
        XCTAssertNotNil(Self.element(in: host.view, label: "სატესტო ფოტო"), "start screen")
        session.selectDemo()
        try await shot("describing", window, directory)
        session.submit("ნიჟარა ჟონავს")
        try await shot("scanning", window, directory, wait: 0.8)
        try await waitForFinishedSteps(session, timeout: 15)
        if !(try await waitForMeshes(session)) { print("PhotoMultiRoundTests: round 1 meshes did not arrive within 20 s") }
        try await shot("step-1", window, directory)
        model.next(); model.next()
        try await shot("step-last", window, directory)

        let newPhoto = try XCTUnwrap(Self.element(in: host.view, label: "ახალი ფოტო"), "ახალი ფოტო button")
        XCTAssertTrue(newPhoto.accessibilityActivate())
        try await shot("photo-request", window, directory)

        session.continueWithDemo()
        guard case .scanning = model.phase else { return XCTFail("expected scanning, got \(model.phase)") }
        try await shot("round2-scanning", window, directory, wait: 0.8)

        try await waitForFinishedSteps(session, timeout: 15)
        if !(try await waitForMeshes(session)) { print("PhotoMultiRoundTests: round 2 meshes did not arrive within 20 s") }
        XCTAssertEqual(model.currentStepIndex, 3)
        try await shot("round2-step4", window, directory)

        model.next(); model.next()
        try await shot("round2-step6-finish", window, directory)

        model.previous(); model.previous(); model.previous()
        XCTAssertEqual(model.displayedRound, 1)
        try await shot("back-to-round1", window, directory)

        model.next(); model.next(); model.next()
        model.finish()
        try await shot("done", window, directory)
    }

    func testDiagnosticCycleThroughAnswerAndMeasurementCards() async throws {
        let session = PhotoSession(api: MockKadriAPI(scanDelay: .milliseconds(5), stepDelay: .milliseconds(5), diagnostic: true))
        let model = session.model
        let host = UIHostingController(rootView: PhotoFlowView(session: session))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        session.selectDemo()
        session.submit("შეამოწმე")
        try await waitForFinishedSteps(session)
        let image = session.image
        model.next(); model.next()
        try await poll(2, "answer action") { Self.element(in: host.view, label: "პასუხი") != nil }
        XCTAssertTrue(try XCTUnwrap(Self.element(in: host.view, label: "პასუხი")).accessibilityActivate())
        try await poll(2, "answer options") { Self.element(in: host.view, label: "კი") != nil }
        XCTAssertTrue(try XCTUnwrap(Self.element(in: host.view, label: "კი")).accessibilityActivate())
        try await poll(2, "answer sent") { model.answers.count == 1 }
        try await waitForFinishedSteps(session)
        XCTAssertEqual(model.allSteps.count, 5)
        XCTAssertEqual(model.stepOffset, 3)
        XCTAssertTrue(session.image === image)
        model.next()
        try await poll(2, "measurement action") { Self.element(in: host.view, label: "გაზომვა") != nil }
        XCTAssertTrue(try XCTUnwrap(Self.element(in: host.view, label: "გაზომვა")).accessibilityActivate())
        try await poll(2, "measurement card") { Self.element(in: host.view, label: "არ მაქვს ხელსაწყო") != nil }
        XCTAssertNotNil(Self.element(in: host.view, label: "გაზომვის მნიშვნელობა"))
        XCTAssertTrue(try XCTUnwrap(Self.element(in: host.view, label: "არ მაქვს ხელსაწყო")).accessibilityActivate())
        try await poll(2, "measurement sent") { model.answers.count == 2 }
        try await waitForFinishedSteps(session)
        XCTAssertEqual(model.allSteps.count, 7)
        XCTAssertEqual(model.round, 1)
        XCTAssertNil(model.answers.last?.unit)
        XCTAssertEqual(model.foundCause, "პარაზიტული დენი სალონის განათებიდან")
        model.next()
        try await poll(2, "finish action") { Self.element(in: host.view, label: "დასრულება") != nil }
        XCTAssertTrue(try XCTUnwrap(Self.element(in: host.view, label: "დასრულება")).accessibilityActivate())
        try await poll(2, "done") { if case .done = model.phase { return true }; return false }
    }

    // MARK: - Helpers

    private func waitForFinishedSteps(_ session: PhotoSession, timeout: TimeInterval = 5) async throws {
        try await poll(timeout, "finished steps") {
            session.phaseChanged()
            if case .steps(_, _, streaming: false) = session.model.phase { return true }
            return false
        }
    }

    /// SAM can be slow on the simulator; screens go on without meshes after 20 s.
    private func waitForMeshes(_ session: PhotoSession) async throws -> Bool {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if session.segmentationStatus == nil && !session.meshes.isEmpty { return true }
            if session.segmentationStatus == "ბადის გარეშე" { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func poll(_ timeout: TimeInterval, _ what: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !done() {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func shot(_ name: String, _ window: UIWindow, _ directory: URL, wait: TimeInterval = 1.2) async throws {
        window.rootViewController?.view.setNeedsLayout()
        window.rootViewController?.view.layoutIfNeeded()
        try await Task.sleep(for: .seconds(wait))
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        let data = try XCTUnwrap(image.pngData())
        XCTAssertGreaterThan(data.count, 1000)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func element(in root: NSObject, label: String) -> NSObject? {
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        var children: [NSObject] = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children {
            if let found = element(in: child, label: label) { return found }
        }
        return nil
    }
}

/// The multi-photo mock, except that the second photo's scan fails after a short wait.
private final class FailingRoundTwoAPI: KadriAPI, @unchecked Sendable {
    private let base = MockKadriAPI(scanDelay: .milliseconds(5), stepDelay: .milliseconds(5), multiPhoto: true)

    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        guard context == nil else {
            try await Task.sleep(for: .milliseconds(800))
            throw URLError(.notConnectedToInternet)
        }
        return try await base.parts(keyframe: keyframe, instructions: instructions, context: context)
    }

    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        base.steps(object: object, parts: parts, instructions: instructions, context: context)
    }
}
