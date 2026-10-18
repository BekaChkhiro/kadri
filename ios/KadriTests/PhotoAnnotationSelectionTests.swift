import XCTest
import KadriCore
@testable import Kadri

@MainActor
final class PhotoAnnotationSelectionTests: XCTestCase {
    private let viewport = CGSize(width: 390, height: 400)
    private let parts = (1...5).map { Part(id: "p\($0)", name: "ნაწილი \($0)", box: [100, 100, 200, 200]) }
    private var boxes: [String: CGRect] {
        Dictionary(uniqueKeysWithValues: parts.enumerated().map { index, part in
            (part.id, CGRect(x: 30 + index * 60, y: 120, width: 40, height: 40))
        })
    }

    func testExplicitTargetsNeverFallBackToWrongDirectionWhenBudgetIsFull() {
        let step = Step(index: 0, title: "მოძრაობა", text: "",
            arrows: (1...4).map { .init(part: "p\($0)", type: "move", dir: "left") },
            actions: [.init(part: "p4", kind: "slide"), .init(part: "p5", kind: "lift")])
        let result = PhotoAnnotationSelection.make(step: step, parts: parts, boxes: boxes, viewport: viewport)
        XCTAssertEqual(result.arrows.map(\.part), ["p1", "p2", "p3"])
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testArrowsAndActionsShareOneBudgetAndAvoidTargetsStayExcluded() {
        let step = Step(index: 0, title: "მოძრაობა", text: "", avoid: ["p2"],
            arrows: [.init(part: "p1", type: "move", dir: "left")],
            actions: (2...5).map { .init(part: "p\($0)", kind: "lift") })
        let result = PhotoAnnotationSelection.make(step: step, parts: parts, boxes: boxes, viewport: viewport)
        XCTAssertEqual(result.actions.map(\.part), ["p3", "p4"])
        XCTAssertEqual(result.arrows.count + result.actions.count, 3)
    }

    func testExplicitRotationKeepsAmountAndOverlappingSequenceKeepsEveryPosition() {
        let step = Step(index: 0, title: "მოუჭირე", text: "",
            arrows: [.init(part: "p1", type: "rotate", dir: "cw")],
            actions: [.init(part: "p1", kind: "rotate_cw", amount: "¼"),
                      .init(part: "p1", kind: "tighten_order", order: ["p1", "p2", "p3", "p4"])])
        let result = PhotoAnnotationSelection.make(step: step, parts: parts, boxes: boxes, viewport: viewport)
        XCTAssertTrue(result.actions.isEmpty)
        XCTAssertEqual(result.orderNumbers, ["p1": 1, "p2": 2, "p3": 3, "p4": 4])
        XCTAssertEqual(result.markers.count, 4)
        XCTAssertTrue(result.markers.first { $0.part == "p1" }!.label.contains("¼ ბრუნი"))
    }

    func testPartialSequenceDoesNotRenumberOrAnnotateAvoidTarget() {
        let step = Step(index: 0, title: "მოუჭირე", text: "", avoid: ["p1"],
            actions: [.init(part: "p1", kind: "tighten_order", order: ["p1", "missing", "p3"])])
        let result = PhotoAnnotationSelection.make(step: step, parts: parts, boxes: boxes, viewport: viewport)
        XCTAssertEqual(result.orderNumbers, ["p3": 3])
        XCTAssertEqual(result.markers.map(\.part), ["p3"])
    }

    func testHiddenPanelTargetsAreExcludedAndLabelsStayInsideVisibleArea() throws {
        let visible = CGSize(width: 390, height: 200)
        let layouts = PhotoArrowLayout.make(arrows: [
            .init(part: "near", type: "move", dir: "away"),
            .init(part: "hidden", type: "move", dir: "up")
        ], boxes: ["near": .init(x: 170, y: 150, width: 50, height: 50),
                   "hidden": .init(x: 170, y: 240, width: 50, height: 50)], viewport: visible)
        XCTAssertEqual(layouts.map(\.id), ["near"])
        XCTAssertTrue(CGRect(origin: .zero, size: visible).contains(try XCTUnwrap(layouts.first).labelRect(viewport: visible)))
    }

    func testPinsReserveArrowAndDepthLabelSpace() throws {
        let box = CGRect(x: 150, y: 130, width: 60, height: 60)
        let layout = try XCTUnwrap(PhotoArrowLayout.make(arrows: [PhotoArrowKind.toward.arrow],
            boxes: ["p1": box], viewport: viewport).first)
        let obstacles = layout.occupiedRects(viewport: viewport)
        let pin = try XCTUnwrap(PhotoGeometry.pinRects(pins: [.init(part: "p1", size: .init(width: 130, height: 30), prefersBelow: true)],
            boxes: ["p1": box], focus: ["p1"], viewport: viewport, visibleHeight: viewport.height,
            occupiedRects: obstacles).first!)
        XCTAssertTrue(obstacles.allSatisfy { !pin.intersects($0) })
    }
}
