import XCTest
import ImageIO
import KadriCore
@testable import Kadri

final class PhotoGeometryTests: XCTestCase {
    func testClusteredPinsAvoidEachOtherAndChips() throws {
        let boxes = ["p3": CGRect(x: 130, y: 62, width: 100, height: 90),
                     "p9": CGRect(x: 95, y: 240, width: 100, height: 65),
                     "p10": CGRect(x: 210, y: 240, width: 90, height: 65)]
        let pins = ["p3", "p9", "p10"].map {
            PhotoGeometry.Pin(part: $0, size: CGSize(width: 190, height: 28))
        }
        let rects = try PhotoGeometry.pinRects(pins: pins, boxes: boxes, focus: Array(boxes.keys),
            viewport: CGSize(width: 402, height: 500), visibleHeight: 380).map { try XCTUnwrap($0) }
        for (i, rect) in rects.enumerated() {
            XCTAssertGreaterThanOrEqual(rect.minY, 60)
            XCTAssertLessThanOrEqual(rect.maxY, 380)
            XCTAssertGreaterThanOrEqual(rect.minX, 8)
            XCTAssertLessThanOrEqual(rect.maxX, 394)
            for other in rects.dropFirst(i + 1) { XCTAssertFalse(rect.intersects(other)) }
        }
    }

    func testBodyPinAvoidsNeighbouringNutFocus() throws {
        let boxes = ["p6": CGRect(x: 110, y: 210, width: 180, height: 160),
                     "p5": CGRect(x: 140, y: 175, width: 120, height: 70)]
        let rect = try XCTUnwrap(PhotoGeometry.pinRects(
            pins: [.init(part: "p6", size: CGSize(width: 190, height: 28))],
            boxes: boxes, focus: ["p5", "p6"], viewport: CGSize(width: 402, height: 500),
            visibleHeight: 440).first!)
        XCTAssertFalse(rect.intersects(try XCTUnwrap(boxes["p5"])))
    }

    func testPinClampsAtEdgesAndMissingBoxKeepsMarkerIndex() throws {
        let rects = PhotoGeometry.pinRects(pins: [
            .init(part: "missing", size: CGSize(width: 100, height: 28)),
            .init(part: "edge", size: CGSize(width: 600, height: 28), prefersBelow: true)
        ], boxes: ["edge": CGRect(x: 380, y: 390, width: 50, height: 40)], focus: [],
           viewport: CGSize(width: 402, height: 500), visibleHeight: 300)
        XCTAssertNil(rects[0])
        let rect = try XCTUnwrap(rects[1])
        XCTAssertTrue(CGRect(x: 8, y: 60, width: 386, height: 232).contains(rect))
    }

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
        XCTAssertTrue(PhotoGeometry.boxes(parts: [part], viewport: CGSize(width: 390, height: 390), imageSize: CGSize(width: 1024, height: 1024)).isEmpty)
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

    func testSquarePhotoFillsSquareViewport() {
        XCTAssertEqual(PhotoGeometry.imageRect(viewport: CGSize(width: 390, height: 390), imageSize: CGSize(width: 1024, height: 1024)),
                       CGRect(x: 0, y: 0, width: 390, height: 390))
    }

    func testSquareMockBoxesMapStraightOntoViewport() throws {
        let viewport = CGSize(width: 390, height: 390), image = CGSize(width: 1024, height: 1024)
        let boxes = PhotoGeometry.boxes(parts: MockKadriAPI.result.parts, viewport: viewport, imageSize: image)
        for part in MockKadriAPI.result.parts {
            let b = part.box.map { CGFloat($0) * 0.39 }
            assertRect(try XCTUnwrap(boxes[part.id]), equals: CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]))
        }
    }

    func testSquareFocusZoomClampsAndNeverRevealsAnEdge() {
        let image = CGSize(width: 1024, height: 1024), viewport = CGSize(width: 390, height: 390)
        let visible = CGRect(origin: .zero, size: viewport)
        let fitScale = 390.0 / 1024
        let whole = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible, focusBoxes: [])
        assertRect(CGRect(origin: .zero, size: image).applying(whole), equals: visible)
        for box in [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 507, y: 507, width: 10, height: 10),
                    CGRect(x: 1014, y: 1014, width: 10, height: 10)] {
            let mapping = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible, focusBoxes: [box])
            XCTAssertEqual(mapping.a, fitScale * 3, accuracy: 0.0001)
            let rendered = CGRect(origin: .zero, size: image).applying(mapping)
            XCTAssertLessThanOrEqual(rendered.minX, 0.0001)
            XCTAssertLessThanOrEqual(rendered.minY, 0.0001)
            XCTAssertGreaterThanOrEqual(rendered.maxX, viewport.width - 0.0001)
            XCTAssertGreaterThanOrEqual(rendered.maxY, viewport.height - 0.0001)
        }
        let centre = PhotoGeometry.focusTransform(imageSize: image, viewport: viewport, visibleRect: visible,
            focusBoxes: [CGRect(x: 507, y: 507, width: 10, height: 10)])
        let focused = CGRect(x: 507, y: 507, width: 10, height: 10).applying(centre)
        XCTAssertEqual(focused.midX, 195, accuracy: 0.0001)
        XCTAssertEqual(focused.midY, 195, accuracy: 0.0001)
    }

    private func assertRect(_ actual: CGRect, equals expected: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.width, expected.width, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(actual.height, expected.height, accuracy: 0.0001, file: file, line: line)
    }

}

@MainActor
final class PhotoSquareJPEGTests: XCTestCase {
    func testLandscapeAndPortraitBecomeCentreSquares() throws {
        for (size, maxSide, side) in [(CGSize(width: 1500, height: 1000), 768.0, 768.0),
                                      (CGSize(width: 1000, height: 1500), 1536.0, 1000.0),
                                      (CGSize(width: 1000, height: 1500), 768.0, 768.0)] {
            // Red bands outside the centre square, green inside: the crop must keep only green.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let source = UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(origin: .zero, size: size))
                let short = min(size.width, size.height)
                UIColor.green.setFill()
                context.fill(CGRect(x: (size.width - short) / 2, y: (size.height - short) / 2, width: short, height: short))
            }
            let image = try decode(try XCTUnwrap(PhotoSession.squareJPEG(source, maxSide: maxSide)))
            XCTAssertEqual(image.width, Int(side)); XCTAssertEqual(image.height, Int(side))
            let edge = Int(side) - 3
            for (x, y) in [(2, 2), (edge, 2), (2, edge), (edge, edge), (Int(side) / 2, Int(side) / 2)] {
                let pixel = try rgb(image, x: x, y: y)
                XCTAssertGreaterThan(pixel.g, 200, "\(size) at \(x),\(y)"); XCTAssertLessThan(pixel.r, 60, "\(size) at \(x),\(y)")
            }
        }
    }

    func testOrientationIsBakedIn() throws {
        // 300×200 pixels whose top rows are red; `.right` shows them as the right edge of a 200×300 photo.
        let context = try XCTUnwrap(CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(UIColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x: 0, y: 150, width: 300, height: 50))
        let source = UIImage(cgImage: try XCTUnwrap(context.makeImage()), scale: 1, orientation: .right)
        XCTAssertEqual(source.size, CGSize(width: 200, height: 300))
        let data = try XCTUnwrap(PhotoSession.squareJPEG(source, maxSide: 1536))
        XCTAssertEqual(try XCTUnwrap(UIImage(data: data)).imageOrientation, .up)
        let image = try decode(data)
        XCTAssertEqual(image.width, 200); XCTAssertEqual(image.height, 200)
        let right = try rgb(image, x: 195, y: 100), left = try rgb(image, x: 5, y: 100)
        XCTAssertGreaterThan(right.r, 200); XCTAssertLessThan(right.b, 60)
        XCTAssertGreaterThan(left.b, 200); XCTAssertLessThan(left.r, 60)
    }

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgb(_ image: CGImage, x: Int, y: Int) throws -> (r: Int, g: Int, b: Int) {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Shift the image so pixel (x, y), counted from the top, lands on the single-pixel context.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(pixel[0]), Int(pixel[1]), Int(pixel[2]))
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
