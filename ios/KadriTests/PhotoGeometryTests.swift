import XCTest
import KadriCore
@testable import Kadri

final class PhotoGeometryTests: XCTestCase {
    func testPortraitFitKeepsWholePhotoCentered() {
        XCTAssertEqual(PhotoGeometry.imageRect(viewport: CGSize(width: 400, height: 450), imageSize: CGSize(width: 1000, height: 1500)),
                       CGRect(x: 50, y: 0, width: 300, height: 450))
    }

    func testLandscapeFitKeepsWholePhotoCentered() {
        XCTAssertEqual(PhotoGeometry.imageRect(viewport: CGSize(width: 400, height: 450), imageSize: CGSize(width: 1500, height: 1000)),
                       CGRect(x: 0, y: (450 - 800.0 / 3) / 2, width: 400, height: 800.0 / 3))
    }

    func testMockBoxUsesSameFitAsImage() throws {
        let viewport = CGSize(width: 400, height: 450), image = CGSize(width: 1000, height: 1500)
        let parts = MockKadriAPI.result.parts
        let boxes = PhotoGeometry.boxes(parts: parts, viewport: viewport, imageSize: image)
        let transform = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport,
            visibleRect: CGRect(origin: .zero, size: viewport), focusBoxes: [])
        let transformed = PhotoGeometry.boxes(parts: parts, imageSize: image, transform: transform)
        let part = try XCTUnwrap(parts.first)
        let box = try XCTUnwrap(boxes[part.id])
        XCTAssertEqual(box.minX, 50 + CGFloat(part.box[0]) * 0.3, accuracy: 0.001)
        XCTAssertEqual(box.minY, CGFloat(part.box[1]) * 0.45, accuracy: 0.001)
        for (id, box) in boxes {
            assertRect(box, equals: try XCTUnwrap(transformed[id]))
        }
    }

    func testInvalidBoxIsOmitted() throws {
        let part = try JSONDecoder().decode(Part.self, from: Data(#"{"id":"bad","name":"bad","box":[100,100,90,200]}"#.utf8))
        XCTAssertTrue(PhotoGeometry.boxes(parts: [part], viewport: CGSize(width: 390, height: 450), imageSize: CGSize(width: 1024, height: 1536)).isEmpty)
    }

    func testEmptyAndOutsideFocusUseFit() {
        let viewport = CGSize(width: 400, height: 450)
        for image in [CGSize(width: 1000, height: 1500), CGSize(width: 1500, height: 1000)] {
            for boxes in [[], [CGRect(x: -100, y: -100, width: 10, height: 10)]] as [[CGRect]] {
                let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport,
                    visibleRect: CGRect(origin: .zero, size: viewport), focusBoxes: boxes)
                assertRect(CGRect(origin: .zero, size: image).applying(mapping),
                           equals: PhotoGeometry.imageRect(viewport: viewport, imageSize: image))
            }
        }
    }

    func testFocusUnionFitsWithPaddingAndCentersInPhotoArea() {
        let image = CGSize(width: 1000, height: 1500), viewport = CGSize(width: 400, height: 450)
        let visible = CGRect(origin: .zero, size: viewport)
        let boxes = [CGRect(x: 300, y: 600, width: 200, height: 100), CGRect(x: 500, y: 700, width: 200, height: 100)]
        let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible, focusBoxes: boxes)
        let union = boxes[0].union(boxes[1]).applying(mapping)
        XCTAssertEqual(union.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(union.midY, visible.midY, accuracy: 0.001)
        XCTAssertEqual(union.width * 1.25, visible.width, accuracy: 0.001)
    }

    func testEdgeFocusClampsEnlargedAxesAndCentersNarrowAxes() {
        let viewport = CGSize(width: 400, height: 450)
        for image in [CGSize(width: 1000, height: 1500), CGSize(width: 1500, height: 1000),
                      CGSize(width: 100, height: 1500), CGSize(width: 1500, height: 100)] {
            for box in [CGRect(x: 0, y: 0, width: 10, height: 10),
                        CGRect(x: image.width - 10, y: image.height - 10, width: 10, height: 10)] {
                let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport,
                    visibleRect: CGRect(origin: .zero, size: viewport), focusBoxes: [box])
                let rendered = CGRect(origin: .zero, size: image).applying(mapping)
                if rendered.width < viewport.width {
                    XCTAssertEqual(rendered.midX, viewport.width / 2, accuracy: 0.001)
                } else {
                    XCTAssertLessThanOrEqual(rendered.minX, 0)
                    XCTAssertGreaterThanOrEqual(rendered.maxX, viewport.width)
                }
                if rendered.height < viewport.height {
                    XCTAssertEqual(rendered.midY, viewport.height / 2, accuracy: 0.001)
                } else {
                    XCTAssertLessThanOrEqual(rendered.minY, 0)
                    XCTAssertGreaterThanOrEqual(rendered.maxY, viewport.height)
                }
            }
        }
    }

    func testZoomStaysBetweenFitAndThreeTimesFit() {
        let image = CGSize(width: 1000, height: 1500), viewport = CGSize(width: 400, height: 450)
        let visible = CGRect(origin: .zero, size: viewport)
        let fitScale = PhotoGeometry.imageRect(viewport: viewport, imageSize: image).width / image.width
        let tiny = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible,
            focusBoxes: [CGRect(x: 450, y: 650, width: 10, height: 10)])
        XCTAssertEqual(tiny.a, fitScale * 3, accuracy: 0.001)
        let whole = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible,
            focusBoxes: [CGRect(origin: .zero, size: image)])
        XCTAssertEqual(whole.a, fitScale, accuracy: 0.001)
        XCTAssertEqual(whole.d, whole.a)
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, file: file, line: line)
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
        XCTAssertNotNil(PhotoIcon.tool("bucket"))
    }
}
