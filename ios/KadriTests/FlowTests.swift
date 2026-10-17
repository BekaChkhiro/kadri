import XCTest
import KadriCore
@testable import Kadri

final class FlowTests: XCTestCase {
    func testTokenPrecedenceAndMissingArgument() {
        XCTAssertEqual(DevAuth.token(arguments: ["app", "--dev-token", " launch "], defaults: "defaults", plist: "plist"), "launch")
        XCTAssertEqual(DevAuth.token(arguments: [], defaults: " ", plist: "plist"), "plist")
        XCTAssertNil(DevAuth.token(arguments: ["--dev-token", "--mock-keyframe"], defaults: "fallback", plist: nil))
        XCTAssertNil(DevAuth.token(arguments: ["--dev-token"], defaults: nil, plist: nil))
    }

    func testExpiryIsReadAndExpiredOrMalformedTokensRejected() throws {
        func token(exp: Int) -> String {
            let payload = Data("{\"exp\":\(exp)}".utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "header.\(payload).signature"
        }
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(try DevAuth.session(token: token(exp: 2000), now: now).expiresAt, Date(timeIntervalSince1970: 2000))
        XCTAssertThrowsError(try DevAuth.session(token: token(exp: 999), now: now))
        XCTAssertThrowsError(try DevAuth.session(token: "invalid", now: now))
    }

    func testAvoidWinsOverFocusAndUnknownPartsStayNeutral() {
        let step = Step(index: 1, title: "", text: "", focus: ["p1", "p2"], avoid: ["p2"])
        XCTAssertEqual(FlowMarker.tone(id: "p1", step: step), .brand)
        XCTAssertEqual(FlowMarker.tone(id: "p2", step: step), .danger)
        XCTAssertEqual(FlowMarker.tone(id: "p3", step: step), .neutral)
    }

    func testProjectionWinsAndFallbackUsesAspectFill() {
        let parts = [Part(id: "p1", name: "one", box: [0, 0, 500, 500]),
                     Part(id: "p2", name: "two", box: [250, 250, 750, 750]),
                     Part(id: "bad", name: "bad", box: [1])]
        let projected = PartProjection(id: "p1", center: CGPoint(x: 30, y: 40), corners: [], returnErrorPixels: nil)
        let markers = FlowMarker.make(parts: parts, projections: [projected], fallback: [],
                                      viewport: CGSize(width: 200, height: 400), imageSize: CGSize(width: 400, height: 400), step: nil)
        XCTAssertEqual(markers.count, 2)
        XCTAssertEqual(markers[0].center, CGPoint(x: 30, y: 40))
        XCTAssertTrue(markers[0].tracked)
        XCTAssertEqual(markers[1].center, CGPoint(x: 100, y: 200))
        XCTAssertFalse(markers[1].tracked)
        let fallback = FlowMarker.make(parts: parts, projections: [], fallback: [("p1", CGPoint(x: 7, y: 9))],
                                      viewport: CGSize(width: 200, height: 400), imageSize: CGSize(width: 400, height: 400), step: nil)
        XCTAssertEqual(fallback[0].center, CGPoint(x: 7, y: 9))
    }
    func testAnchorBehindCameraDoesNotBecomeAFixedMarker() {
        let part = Part(id: "p1", name: "one", box: [100, 100, 500, 500])
        XCTAssertTrue(FlowMarker.make(parts: [part], projections: [], fallback: [],
            viewport: CGSize(width: 200, height: 400), imageSize: CGSize(width: 400, height: 400),
            step: nil, anchoredIDs: ["p1"]).isEmpty)
    }

}
