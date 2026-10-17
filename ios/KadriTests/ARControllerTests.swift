import XCTest
import ARKit
@testable import Kadri

final class ARControllerTests: XCTestCase {
    @MainActor func testUnsupportedSessionDoesNotStart() {
        let controller = ARSessionController()
        if !ARWorldTrackingConfiguration.isSupported {
            controller.start()
            XCTAssertEqual(controller.status, "AR მიუწვდომელია")
            XCTAssertNil(controller.latest)
            XCTAssertNil(controller.keyframe)
        }
        controller.pause()
    }
    @MainActor func testEmptyAnchorStore() {
        let store = PartAnchors()
        store.clear(session: ARSession())
        XCTAssertTrue(store.placements.isEmpty)
        XCTAssertTrue(store.anchorIDs.isEmpty)
        XCTAssertTrue(store.unanchored.isEmpty)
    }
}
