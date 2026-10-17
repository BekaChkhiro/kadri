import XCTest
import KadriCore
@testable import Kadri

final class PhotoGeometryTests: XCTestCase {
    func testCoverCropsHorizontally() {
        let rect = PhotoGeometry.imageRect(viewport: CGSize(width: 390, height: 844), imageSize: CGSize(width: 1024, height: 1536))
        XCTAssertEqual(rect.width, 562.6666667, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 844)
        XCTAssertEqual(rect.minX, -86.3333333, accuracy: 0.0001)
        XCTAssertEqual(rect.minY, 0)
    }

    func testCoverCropsVertically() {
        XCTAssertEqual(PhotoGeometry.imageRect(viewport: CGSize(width: 800, height: 400), imageSize: CGSize(width: 400, height: 800)),
                       CGRect(x: 0, y: -600, width: 800, height: 1600))
    }

    func testMockBoxUsesSameCropAsImage() throws {
        let boxes = PhotoGeometry.boxes(parts: MockKadriAPI.result.parts, viewport: CGSize(width: 390, height: 844), imageSize: CGSize(width: 1024, height: 1536))
        let box = try XCTUnwrap(boxes["p1"])
        XCTAssertEqual(box.minX, 31.8266667, accuracy: 0.0001)
        XCTAssertEqual(box.minY, 177.24, accuracy: 0.0001)
        XCTAssertEqual(box.width, 61.8933333, accuracy: 0.0001)
        XCTAssertEqual(box.height, 105.5, accuracy: 0.0001)
    }

    func testInvalidBoxIsOmitted() throws {
        let part = try JSONDecoder().decode(Part.self, from: Data(#"{"id":"bad","name":"bad","box":[100,100,90,200]}"#.utf8))
        XCTAssertTrue(PhotoGeometry.boxes(parts: [part], viewport: CGSize(width: 390, height: 844), imageSize: CGSize(width: 1024, height: 1536)).isEmpty)
    }
}

final class PhotoStepPresentationTests: XCTestCase {
    func testWaitsUntilAnotherStepArrives() {
        XCTAssertEqual(PhotoStepPresentation.state(index: 0, count: 1, streaming: true), .preparing)
        XCTAssertTrue(PhotoStepPresentation.state(index: 0, count: 1, streaming: true).disabled)
        XCTAssertEqual(PhotoStepPresentation.state(index: 0, count: 2, streaming: true), .next)
        XCTAssertFalse(PhotoStepPresentation.state(index: 0, count: 2, streaming: true).disabled)
    }

    func testFinishesOnlyAfterStreamCompletes() {
        XCTAssertEqual(PhotoStepPresentation.state(index: 4, count: 5, streaming: true), .preparing)
        XCTAssertEqual(PhotoStepPresentation.state(index: 4, count: 5, streaming: false), .finish)
        XCTAssertEqual(PhotoStepPresentation.state(index: 0, count: 5, streaming: false), .next)
    }

    func testNoStepsAlwaysDisablesButton() {
        for streaming in [true, false] {
            let state = PhotoStepPresentation.state(index: 0, count: 0, streaming: streaming)
            XCTAssertEqual(state, .preparing)
            XCTAssertTrue(state.disabled)
        }
    }
}
