import XCTest

/// Uses the system UI automation process, including on iOS versions that do not expose SwiftUI's tree to hosted unit tests.
@MainActor
final class PhotoProblemUITests: XCTestCase {
    func testTwoPhotosSubmitAndReopenWithoutBlankScreen() throws {
        let app = launch()
        defer { app.terminate() }
        send(app)
        XCTAssertTrue(app.staticTexts["სატესტო კითხვა 1"].waitForExistence(timeout: 10))
        attach(app, name: "iPhone-two-photo-analysis")
        let close = app.navigationBars.buttons["დახურვა"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        send(app)
        XCTAssertTrue(app.staticTexts["სატესტო კითხვა 2"].waitForExistence(timeout: 10), "Reopening must create a fresh analysis and request")
        attach(app, name: "iPhone-reopened-analysis")
    }

    func testRequestFailureShowsRetryAndRecovers() throws {
        let app = launch(failFirst: true)
        defer { app.terminate() }
        send(app)
        let retry = app.buttons["ხელახლა ცდა"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        attach(app, name: "iPhone-visible-analysis-error")
        if !retry.isHittable { app.swipeUp() }
        retry.tap()
        XCTAssertTrue(app.staticTexts["სატესტო კითხვა 2"].waitForExistence(timeout: 10))
        attach(app, name: "iPhone-retry-success")
    }

    private func launch(failFirst: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-test-multi-photo"]
        if failFirst { app.launchArguments.append("--ui-test-problem-failure") }
        app.launch()
        XCTAssertTrue(app.buttons["გაგზავნა"].waitForExistence(timeout: 10))
        return app
    }

    private func send(_ app: XCUIApplication) {
        let send = app.buttons["გაგზავნა"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
