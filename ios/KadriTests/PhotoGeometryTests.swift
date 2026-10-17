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
    func testVisibleAreaExcludesMeasuredCardAndBottomInset() {
        XCTAssertEqual(PhotoGeometry.visibleRect(viewport: CGSize(width: 390, height: 750), cardHeight: 300, bottomInset: 34),
                       CGRect(x: 0, y: 0, width: 390, height: 400))
        XCTAssertEqual(PhotoGeometry.visibleRect(viewport: CGSize(width: 390, height: 300), cardHeight: 400, bottomInset: 34).height, 0)
    }

    func testEmptyFocusUsesCover() {
        let image = CGSize(width: 1024, height: 1536), viewport = CGSize(width: 390, height: 750)
        let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport,
            visibleRect: CGRect(x: 0, y: 0, width: 390, height: 400), focusBoxes: [])
        XCTAssertEqual(CGRect(origin: .zero, size: image).applying(mapping),
                       PhotoGeometry.imageRect(viewport: viewport, imageSize: image))
    }

    func testFocusUnionFitsAndCentersAboveCard() {
        let image = CGSize(width: 1000, height: 1500), viewport = CGSize(width: 400, height: 800)
        let visible = CGRect(x: 0, y: 0, width: 400, height: 400)
        let boxes = [CGRect(x: 350, y: 450, width: 100, height: 100), CGRect(x: 450, y: 500, width: 150, height: 100)]
        let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible, focusBoxes: boxes)
        let union = boxes[0].union(boxes[1]).applying(mapping)
        XCTAssertEqual(union.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(union.midY, visible.midY, accuracy: 0.001)
        XCTAssertTrue(visible.contains(union))
        XCTAssertEqual(union.width * 1.25, visible.width, accuracy: 0.001)
    }

    func testEdgeFocusClampsImageWithoutExposingEdges() {
        let image = CGSize(width: 1000, height: 1500), viewport = CGSize(width: 400, height: 800)
        for box in [CGRect(x: 0, y: 0, width: 50, height: 50), CGRect(x: 950, y: 1450, width: 50, height: 50)] {
            let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport,
                visibleRect: CGRect(x: 0, y: 0, width: 400, height: 400), focusBoxes: [box])
            let rendered = CGRect(origin: .zero, size: image).applying(mapping)
            XCTAssertLessThanOrEqual(rendered.minX, 0)
            XCTAssertLessThanOrEqual(rendered.minY, 0)
            XCTAssertGreaterThanOrEqual(rendered.maxX, viewport.width)
            XCTAssertGreaterThanOrEqual(rendered.maxY, viewport.height)
        }
    }

    func testSmallFocusCapsZoomAtThreeTimesCover() {
        let image = CGSize(width: 1000, height: 1500), viewport = CGSize(width: 400, height: 800)
        let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport,
            visibleRect: CGRect(x: 0, y: 0, width: 400, height: 400),
            focusBoxes: [CGRect(x: 450, y: 450, width: 10, height: 10)])
        let coverScale = PhotoGeometry.imageRect(viewport: viewport, imageSize: image).width / image.width
        XCTAssertEqual(mapping.a, coverScale * 3, accuracy: 0.001)
        XCTAssertEqual(mapping.d, mapping.a)
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

@MainActor
final class PhotoIconTests: XCTestCase {
    func testUnknownAndEmptyIconsHaveNoSymbol() {
        for key in [nil, "", "unknown", "arrow.up"] as [String?] {
            XCTAssertNil(PhotoIcon.action(key))
            XCTAssertNil(PhotoIcon.tool(key))
        }
        XCTAssertEqual(PhotoIcon.action("rotate_cw"), "arrow.clockwise")
        XCTAssertEqual(PhotoIcon.tool("cloth"), "rectangle.portrait")
    }
}
