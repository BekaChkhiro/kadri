import XCTest
import UIKit
import KadriCore
@testable import Kadri

final class PhotoArrowOverlayTests: XCTestCase {
    private let viewport = CGSize(width: 390, height: 500)
    private let box = CGRect(x: 140, y: 170, width: 90, height: 80)

    func testEverySupportedInstructionHasAnInstalledSystemSymbol() {
        for kind in PhotoArrowKind.allCases {
            XCTAssertNotNil(UIImage(systemName: kind.symbolName), "Missing SF Symbol: \(kind.symbolName)")
            XCTAssertEqual(PhotoArrowKind(arrow: kind.arrow), kind)
        }
        XCTAssertNil(PhotoArrowKind(arrow: .init(part: "p1", type: "rotate", dir: "up")))
        XCTAssertNil(PhotoArrowKind(arrow: .init(part: "p1", type: "move", dir: "cw")))
        XCTAssertNil(PhotoArrowKind(arrow: .init(part: "p1", type: "press", dir: "down")))
    }

    func testUnsafeMissingAndInvalidTargetsAreNotAnnotated() {
        let arrows = ["avoid", "missing", "empty", "nan", "outside", "good"].map {
            StepArrow(part: $0, type: "move", dir: "up")
        }
        let layouts = PhotoArrowLayout.make(arrows: arrows, boxes: [
            "avoid": box, "empty": .zero,
            "nan": .init(x: CGFloat.nan, y: 0, width: 40, height: 40),
            "outside": .init(x: 800, y: 800, width: 40, height: 40), "good": box
        ], avoid: ["avoid"], viewport: viewport)
        XCTAssertEqual(layouts.map(\.id), ["good"])
    }

    func testAnnotationFollowsTargetWhileSizeStaysStableAcrossZoom() throws {
        let base = try XCTUnwrap(PhotoArrowLayout.make(arrows: [PhotoArrowKind.clockwise.arrow],
            boxes: ["p1": box], sizeBoxes: ["p1": box], viewport: viewport).first)
        let zoomedBox = CGRect(x: 100, y: 150, width: 180, height: 160)
        let zoomed = try XCTUnwrap(PhotoArrowLayout.make(arrows: [PhotoArrowKind.clockwise.arrow],
            boxes: ["p1": zoomedBox], sizeBoxes: ["p1": box], viewport: viewport).first)
        XCTAssertEqual(base.size, zoomed.size)
        XCTAssertEqual(zoomed.anchor, CGPoint(x: 190, y: 230))
        XCTAssertEqual(zoomed.center, zoomed.anchor)
    }

    func testSmallAndLargeTargetsRemainLegibleAndBounded() throws {
        for target in [CGRect(x: 0, y: 0, width: 2, height: 2), CGRect(x: 0, y: 0, width: 800, height: 800)] {
            let layout = try XCTUnwrap(PhotoArrowLayout.make(arrows: [PhotoArrowKind.upLeft.arrow],
                boxes: ["p1": target], viewport: viewport).first)
            XCTAssertGreaterThanOrEqual(layout.size, 44)
            XCTAssertLessThanOrEqual(layout.size, 92)
            for phase in stride(from: CGFloat(0), through: 1, by: 0.1) {
                let motion = PhotoArrowMotion.sample(kind: layout.kind, phase: phase, size: layout.size)
                let rect = CGRect(x: layout.center.x + motion.offset.width - layout.size / 2,
                                  y: layout.center.y + motion.offset.height - layout.size / 2,
                                  width: layout.size, height: layout.size)
                XCTAssertTrue(CGRect(origin: .zero, size: viewport).contains(rect))
            }
        }
    }

    func testMovementNeverReversesAndResetIsInvisible() {
        let kinds: [PhotoArrowKind] = [.up, .down, .left, .right, .upLeft, .upRight, .downLeft, .downRight]
        for kind in kinds {
            var previous: CGFloat = -1
            for phase in stride(from: CGFloat(0), through: 1, by: 0.05) {
                let motion = PhotoArrowMotion.sample(kind: kind, phase: phase, size: 64)
                let distance = motion.offset.width * kind.vector.dx + motion.offset.height * kind.vector.dy
                XCTAssertGreaterThanOrEqual(distance, previous)
                previous = distance
            }
            XCTAssertEqual(PhotoArrowMotion.sample(kind: kind, phase: 0, size: 64).opacity, 0)
            XCTAssertEqual(PhotoArrowMotion.sample(kind: kind, phase: 1, size: 64).opacity, 0)
        }
        XCTAssertGreaterThan(PhotoArrowMotion.sample(kind: .clockwise, phase: 0.5, size: 64).degrees, 0)
        XCTAssertLessThan(PhotoArrowMotion.sample(kind: .counterclockwise, phase: 0.5, size: 64).degrees, 0)
        XCTAssertGreaterThan(PhotoArrowMotion.sample(kind: .toward, phase: 0.8, size: 64).scale, 1)
        XCTAssertLessThan(PhotoArrowMotion.sample(kind: .away, phase: 0.8, size: 64).scale, 1)
    }

    func testReducedMotionIsFullyVisibleAndStillForEveryAction() {
        for kind in PhotoArrowKind.allCases {
            let motion = PhotoArrowMotion.sample(kind: kind, phase: 0, size: 64, reduced: true)
            XCTAssertEqual(motion.offset, .zero)
            XCTAssertEqual(motion.degrees, 0)
            XCTAssertEqual(motion.scale, 1)
            XCTAssertEqual(motion.opacity, 1)
        }
    }

    func testOneInstructionPerPartAndAtMostThreeVisibleTargets() {
        let arrows = ["a", "a", "b", "c", "d"].map { StepArrow(part: $0, type: "move", dir: "right") }
        let boxes = Dictionary(uniqueKeysWithValues: ["a", "b", "c", "d"].map { ($0, box) })
        XCTAssertEqual(PhotoArrowLayout.make(arrows: arrows, boxes: boxes, viewport: viewport).map(\.id), ["a", "b", "c"])
    }
}
