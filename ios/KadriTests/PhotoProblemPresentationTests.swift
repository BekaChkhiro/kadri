// iOS18 devices expose this SwiftUI tree through XCUITest, covered by KadriUITests.
#if targetEnvironment(simulator)
import SwiftUI
import UIKit
import XCTest
import KadriCore
@testable import Kadri

/// Exercise the actual draft button and modal boundary; constructing the result view directly misses stale presentation state.
@MainActor
final class PhotoProblemPresentationTests: XCTestCase {
    func testRealSendButtonPresentsTwoPhotoAnalysisAndReopensWithFreshDescription() async throws {
        let api = PresentationProblemAPI()
        let session = makeSession(api: api)
        let (window, host, previous) = try host(session)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        XCTAssertNil(host.presentedViewController)
        try await activate("გაგზავნა", in: window)
        await waitForRequests(api, count: 1)
        _ = try await element(PresentationProblemAPI.question, in: window)
        capture(window, name: "populated-two-photo-analysis")
        XCTAssertNotNil(host.presentedViewController, "The real send action must open a populated analysis cover")
        var requests = await api.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.photos, session.draftPhotos)
        XCTAssertEqual(requests.first?.problem, "ორი ფოტო ერთი პრობლემისაა")

        // The underlying photo screen also has a close button; target only the presented cover.
        let presented = try XCTUnwrap(host.presentedViewController)
        try await activate("დახურვა", in: presented.view)
        for _ in 0..<150 {
            if host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(host.presentedViewController)
        session.model.updateText("განახლებული აღწერა იმავე ფოტოებით")
        try await activate("გაგზავნა", in: window)
        await waitForRequests(api, count: 2)
        _ = try await element(PresentationProblemAPI.question, in: window)
        requests = await api.requests
        XCTAssertEqual(requests.count, 2, "Reopening submits exactly once with a fresh problem model")
        XCTAssertEqual(requests.last?.problem, "განახლებული აღწერა იმავე ფოტოებით")
        XCTAssertEqual(requests.last?.photos, session.draftPhotos)
        host.dismiss(animated: false)
    }

    func testFailedRequestShowsRetryInsidePresentedCoverAndRecovers() async throws {
        let api = PresentationProblemAPI(failFirst: true)
        let session = makeSession(api: api)
        let (window, host, previous) = try host(session)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }

        try await activate("გაგზავნა", in: window)
        await waitForRequests(api, count: 1)
        _ = try await element("ხელახლა ცდა", in: window)
        capture(window, name: "visible-analysis-error")
        XCTAssertNotNil(host.presentedViewController, "A backend failure must leave actionable cover content")
        try await activate("ხელახლა ცდა", in: window)
        await waitForRequests(api, count: 2)
        _ = try await element(PresentationProblemAPI.question, in: window)
        let requests = await api.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.sessionId, requests.last?.sessionId)
        XCTAssertEqual(requests.last?.photos, session.draftPhotos)
        host.dismiss(animated: false)
    }

    private func makeSession(api: any KadriAPI) -> PhotoSession {
        let session = PhotoSession(api: api)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format)
        session.select(renderer.image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        })
        XCTAssertTrue(session.addDraftPhoto(renderer.image { context in
            UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }))
        session.model.updateText("ორი ფოტო ერთი პრობლემისაა")
        return session
    }

    private func host(_ session: PhotoSession) throws -> (UIWindow, UIViewController, UIWindow?) {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { PhotoFlowView(session: session) })
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        return (window, host, previous)
    }

    private func activate(_ label: String, in view: UIView) async throws {
        let button = try await element(label, in: view)
        XCTAssertTrue(button.accessibilityActivate(), "Could not activate \(label)")
    }

    private func waitForRequests(_ api: PresentationProblemAPI, count: Int) async {
        for _ in 0..<150 {
            if await api.requests.count >= count { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        let requests = await api.requests
        XCTAssertEqual(requests.count, count, "The presented view must start the analysis request")
    }

    private func capture(_ view: UIView, name: String) {
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ label: String, in view: UIView) async throws -> NSObject {
        for _ in 0..<250 {
            if let found = Self.find(label, in: view) { return found }
            try await Task.sleep(for: .milliseconds(20))
        }
        capture(view, name: "missing-cover-content")
        let hierarchy = XCTAttachment(string: Self.accessibilityDescription(view))
        hierarchy.name = "accessibility-tree"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
        return try XCTUnwrap(Self.find(label, in: view), "Missing visible content: \(label)")
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

    private static func accessibilityDescription(_ root: NSObject, depth: Int = 0) -> String {
        guard depth < 24 else { return "…\n" }
        let count = root.accessibilityElementCount()
        var text = String(repeating: " ", count: depth) + "\(type(of: root)) label=\(root.accessibilityLabel ?? "nil") element=\(root.isAccessibilityElement) count=\(count)\n"
        var children = (root.accessibilityElements as? [NSObject]) ?? []
        if children.isEmpty, count != NSNotFound, count > 0, count < 1000 {
            children = (0..<count).compactMap { root.accessibilityElement(at: $0) as? NSObject }
        }
        if let view = root as? UIView { children += view.subviews }
        for child in children { text += accessibilityDescription(child, depth: depth + 1) }
        return text
    }
}

private actor PresentationProblemAPI: KadriAPI {
    static let question = "ეს ერთი მოწყობილობის ორი ხედია?"
    private(set) var requests: [ProblemRequest] = []
    let failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }
    func problem(_ request: ProblemRequest) async throws -> ProblemResult {
        requests.append(request)
        if failFirst && requests.count == 1 { throw URLError(.notConnectedToInternet) }
        return .init(summary: "ფოტოები მიღებულია", observations: request.photos.map {
            .init(photoId: $0.id, detail: "მოწყობილობის ხედი", relevance: "uncertain")
        }, components: [], links: [], steps: [],
        next: .init(kind: .needsAnswer, prompt: Self.question, reason: "ფოტოების კავშირი დასაზუსტებელია"))
    }
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        throw SessionError.server(code: "unexpected", message: "Single-photo endpoint must not be called")
    }
    nonisolated func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

#endif
