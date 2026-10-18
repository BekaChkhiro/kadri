import XCTest
import SwiftUI
@testable import Kadri

@MainActor
final class PhotoDoneTests: XCTestCase {
    func testPlumbingIllustrations() {
        for object in ["ონკანი", "სიფონი", "წყლის მილი", "ნიჟარა", "უნიტაზი"] {
            XCTAssertEqual(PhotoDoneContent.illustrationName(for: object), "illo-done", object)
        }
        for object in ["PC-ის აწყობა", "კომპიუტერი", "სარეცხი მანქანა", "სკამი", ""] {
            XCTAssertEqual(PhotoDoneContent.illustrationName(for: object), "illo-done-neutral", object)
        }
    }

    func testFoundCause() {
        let content = PhotoDoneContent(cause: "კაბელი არ იყო შეერთებული", summary: "შეაერთე კვების კაბელი.", stepCount: 4)
        XCTAssertEqual(content.title, "მიზეზი ნაპოვნია")
        XCTAssertEqual(content.subtitle, "კაბელი არ იყო შეერთებული")
        XCTAssertEqual(content.summary, "შეაერთე კვების კაბელი.")
        XCTAssertNil(content.cardTitle)
        let causeOnly = PhotoDoneContent(cause: "კაბელი", summary: nil, stepCount: 4)
        XCTAssertEqual(causeOnly.title, "მიზეზი ნაპოვნია")
        XCTAssertNil(causeOnly.summary)
    }

    func testPresumedCause() {
        let content = PhotoDoneContent(cause: nil, summary: "შეამოწმე კვების კაბელი.", stepCount: 4)
        XCTAssertEqual(content.title, "ნაბიჯები შესრულდა")
        XCTAssertNil(content.subtitle)
        XCTAssertEqual(content.cardTitle, "მიზეზი სავარაუდოა — შემოწმება საჭიროა")
        XCTAssertEqual(content.summary, "შეამოწმე კვების კაბელი.")
    }

    func testLegacyCompletion() {
        let content = PhotoDoneContent(cause: nil, summary: nil, stepCount: 4)
        XCTAssertEqual(content.title, "მზადაა!")
        XCTAssertEqual(content.subtitle, "ყველა 4 ნაბიჯი შესრულებულია.")
        XCTAssertNil(content.cardTitle)
        XCTAssertNil(content.summary)
    }

    func testNeutralDoneRendering() async throws {
        XCTAssertNotNil(UIImage(named: "illo-done-neutral"))
        let view = PhotoDoneView(object: "კომპიუტერის აწყობა", steps: [], photos: 3, minutes: 5,
                                 thumbnail: nil, close: {}, newPhoto: {},
                                 diagnosticSummary: "კვების კაბელი სავარაუდოდ არ არის შეერთებული. შეამოწმე შეერთება.")
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(1500))
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        let attachment = XCTAttachment(image: image)
        attachment.name = "done-neutral"
        attachment.lifetime = .keepAlways
        add(attachment)
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: "/tmp/kadri-done-neutral.png"))
    }
}
