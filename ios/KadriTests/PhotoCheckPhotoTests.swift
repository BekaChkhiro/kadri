import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class PhotoCheckPhotoTests: XCTestCase {
    func testCheckPhotoAndPhotoAnswerStayInOneRound() async throws {
        let api = MockKadriAPI.checkPhotoScenario()
        let session = PhotoSession(api: api)
        session.selectDemo()
        let reference = try XCTUnwrap(session.image)
        session.submit("ააწყვე კომპიუტერი")
        try await finished(session)
        XCTAssertEqual(session.model.allSteps.count, 3)
        XCTAssertTrue(session.model.canContinueWithCheckPhoto)
        XCTAssertNotNil(api.images[0])

        let closeup = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900)).image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
        }
        session.continueWithCheckPhoto(closeup)
        XCTAssertEqual(session.model.checkPhotoPhase, .checking)
        try await finished(session)
        XCTAssertEqual(session.model.allSteps.count, 5)
        XCTAssertTrue(session.image === reference)
        XCTAssertEqual(api.partsCount, 1)
        XCTAssertEqual(api.contexts[1]?.checkPhotos, 1)
        XCTAssertEqual(api.contexts[1]?.checkPrompt, MockCheckPhotoAPI.prompt)
        XCTAssertNotEqual(api.images[0], api.images[1])
        let uploaded = try XCTUnwrap(UIImage(data: XCTUnwrap(api.images[1])))
        XCTAssertLessThanOrEqual(max(uploaded.size.width, uploaded.size.height), 768)

        session.model.continueWithAnswer("ფოტოს გაჩვენებ")
        XCTAssertTrue(session.model.answers.isEmpty)
        XCTAssertEqual(api.images.count, 2)
        session.continueWithCheckPhoto(closeup)
        try await finished(session)
        XCTAssertEqual(api.contexts[2]?.checkPrompt, "ბერკეტი დაკეტილია?")
        XCTAssertEqual(api.contexts[2]?.checkPhotos, 2)
        XCTAssertEqual(api.partsCount, 1)
        XCTAssertEqual(session.model.round, 1)
        XCTAssertEqual(session.model.allSteps.count, 6)
        XCTAssertTrue(session.model.continuation?.isComplete == true)
    }

    func testAnswerAfterCheckUsesOriginalKeyframe() async throws {
        let api = MockKadriAPI.checkPhotoScenario()
        let session = PhotoSession(api: api)
        session.selectDemo()
        session.submit("ააწყვე")
        try await finished(session)
        session.continueWithDemo()
        try await finished(session)
        session.model.continueWithAnswer("დიახ")
        try await finished(session)
        XCTAssertEqual(api.images[2], api.images[0])
        XCTAssertEqual(api.contexts[2]?.answers.last?.answer, "დიახ")
        XCTAssertTrue(session.model.continuation?.isComplete == true)
    }

    func testCheckPhotoRequestAndAnswerCameraButtonOnScreen() async throws {
        let session = PhotoSession(api: MockKadriAPI.checkPhotoScenario())
        let host = UIHostingController(rootView: PhotoFlowView(session: session))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        session.selectDemo()
        session.submit("ააწყვე კომპიუტერი")
        try await finished(session)
        session.model.next(); session.model.next()
        try await activate("ახალი ფოტო", in: host.view)
        _ = try await element(MockCheckPhotoAPI.prompt, in: host.view)
        session.continueWithDemo()
        try await finished(session)
        session.model.next()
        try await activate("პასუხი", in: host.view)
        try await activate("ფოტოს გაჩვენებ", in: host.view)
        _ = try await element("ბერკეტი დაკეტილია?", in: host.view)
        XCTAssertTrue(session.model.answers.isEmpty)
        host.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "check-photo-request"
        attachment.lifetime = .keepAlways
        add(attachment)
        session.continueWithDemo()
        try await finished(session)
        XCTAssertTrue(session.model.continuation?.isComplete == true)
    }

    private func activate(_ label: String, in view: UIView) async throws {
        let button = try await element(label, in: view)
        XCTAssertTrue(button.accessibilityActivate())
    }

    private func element(_ label: String, in view: UIView) async throws -> NSObject {
        for _ in 0..<100 {
            if let found = Self.find(label, in: view) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        return try XCTUnwrap(Self.find(label, in: view), "missing \(label)")
    }

    private static func find(_ label: String, in root: NSObject) -> NSObject? {
        if root.isAccessibilityElement, root.accessibilityLabel == label { return root }
        var children = (root.accessibilityElements as? [NSObject]) ?? []
        let count = root.accessibilityElementCount()
        if children.isEmpty, count != NSNotFound, count > 0 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children { if let found = find(label, in: child) { return found } }
        return nil
    }

    private func finished(_ session: PhotoSession) async throws {
        for _ in 0..<250 {
            session.phaseChanged()
            if case .steps(_, _, streaming: false) = session.model.phase { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("steps did not finish: \(session.model.phase)")
    }
}
