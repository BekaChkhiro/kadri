import XCTest
import KadriCore
@testable import Kadri

final class SessionPresentationTests: XCTestCase {
    func testScanStatusBoundaries() {
        XCTAssertEqual(SessionPresentation.scanStatus(elapsed: 0), "ვათვალიერებ…")
        XCTAssertEqual(SessionPresentation.scanStatus(elapsed: 2.99), "ვათვალიერებ…")
        for time in [3.0, 7, 10] {
            XCTAssertEqual(SessionPresentation.scanStatus(elapsed: time), "ვპოულობ ნაწილებს…")
        }
        XCTAssertEqual(SessionPresentation.scanStatus(elapsed: 10.01), "ცოტაც…")
    }

    func testBoxScalesBothAxesIndependently() {
        let part = Part(id: "p1", name: "ონკანი", box: [100, 200, 400, 600])
        let rect = SessionPresentation.rect(for: part, in: CGSize(width: 400, height: 800))!
        XCTAssertEqual(rect.minX, 40, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 160, accuracy: 0.001)
        XCTAssertEqual(rect.width, 120, accuracy: 0.001)
        XCTAssertEqual(rect.height, 320, accuracy: 0.001)
    }

    func testInvalidBoxesAreNotDrawn() {
        for box in [[1, 2], [500, 0, 100, 10], [-1, 0, 500, 1000], [0, 0, 1001, 1000]] {
            XCTAssertNil(SessionPresentation.rect(for: Part(id: "p1", name: "", box: box), in: CGSize(width: 400, height: 800)))
        }
        XCTAssertNil(SessionPresentation.rect(for: MockKadriAPI.result.parts[0], in: .zero))
    }

    func testProgressDistinguishesGrowingAndFinalTotals() {
        XCTAssertEqual(SessionPresentation.progress(index: 0, count: 0, streaming: true), "პირველი ნაბიჯი იწერება…")
        XCTAssertEqual(SessionPresentation.progress(index: 0, count: 1, streaming: true), "ნაბიჯი 1 / 1+")
        XCTAssertEqual(SessionPresentation.progress(index: 0, count: 3, streaming: true), "ნაბიჯი 1 / 3+")
        XCTAssertEqual(SessionPresentation.progress(index: 2, count: 3, streaming: false), "ნაბიჯი 3 / 3")
        XCTAssertEqual(SessionPresentation.progress(index: 9, count: 3, streaming: false), "ნაბიჯი 3 / 3")
    }

    func testProgressWaitsForALaterRoundsFirstStep() {
        XCTAssertEqual(SessionPresentation.progress(index: 3, count: 3, streaming: true), "ნაბიჯი 4 იწერება…")
        XCTAssertEqual(SessionPresentation.progress(index: 3, count: 6, streaming: false), "ნაბიჯი 4 / 6")
        XCTAssertEqual(SessionPresentation.progress(index: 3, count: 4, streaming: true), "ნაბიჯი 4 / 4+")
    }
}
