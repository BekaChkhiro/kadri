import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor final class PhotoProblemFlowTests: XCTestCase {
    func testDemoCorrelatesViewsAndRequiresExplicitResolution() async throws {
        let model = PhotoProblemDemo.model()
        XCTAssertEqual(model.photos.count, 2)
        XCTAssertNotEqual(model.photos[0].image, model.photos[1].image)
        try await render(model, name: "01-draft")
        await model.submit()
        XCTAssertEqual(model.continuation?.kind, .needsAnswer)
        XCTAssertNil(model.currentStep)
        try await render(model, name: "02-question")
        await model.answer("ამ შეერთებაზე ჩნდება")
        XCTAssertEqual(model.currentStep?.photoId, "overall")
        XCTAssertEqual(model.result?.components.first?.views.count, 2)
        try await render(model, name: "03-first-step")
        await model.markCurrentStep(outcome: .done)
        XCTAssertEqual(model.currentStep?.photoId, "detail")
        let overall = ProblemEvidenceView(photo: model.photos[0], result: model.result, step: model.currentStep)
        let detail = ProblemEvidenceView(photo: model.photos[1], result: model.result, step: model.currentStep)
        XCTAssertNil(overall.overlayStep, "Never put a detail-photo action on the overall photo")
        XCTAssertEqual(detail.overlayStep?.arrows.first?.dir, "up")
        XCTAssertEqual(overall.parts.first?.id, detail.parts.first?.id)
        XCTAssertNotEqual(overall.parts.first?.box, detail.parts.first?.box)
        try await render(model, name: "04-detail-step")
        await model.markCurrentStep(outcome: .done)
        XCTAssertEqual(model.continuation?.kind, .verify)
        XCTAssertNotEqual(model.phase, .resolved)
        try await render(model, name: "05-verify")
        await model.confirmResolution()
        XCTAssertEqual(model.phase, .resolved)
        XCTAssertEqual(model.history.count, 2)
        try await render(model, name: "06-resolved")
    }

    func testDemoUnsuccessfulActionDoesNotPretendToResolve() async throws {
        let model = PhotoProblemDemo.model()
        await model.submit()
        await model.answer("შეერთებიდან")
        await model.markCurrentStep(outcome: .unable, note: "ვერ ვხედავ")
        XCTAssertEqual(model.phase, .unresolved)
        XCTAssertNil(model.currentStep)
        XCTAssertEqual(model.history.first?.outcome, .unable)
        try await render(model, name: "07-unresolved")
    }

    private func render(_ model: ProblemSessionModel, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: PhotoProblemFlowView(model: model, isDemo: true)
            .environment(\.photoOverlayReduceMotion, true))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(180))
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        let directory = URL(fileURLWithPath: "/tmp/kadri-problem-shots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
    }
}
