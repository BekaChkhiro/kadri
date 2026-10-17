import XCTest
@testable import KadriCore

final class ModelsTests: XCTestCase {
    func testPartDecodesAndValidatesBox() throws {
        let json = #"{"id":"p1","name":"სიფონი","box":[120,300,480,760]}"#
        let part = try JSONDecoder().decode(Part.self, from: Data(json.utf8))
        XCTAssertEqual(part.id, "p1")
        XCTAssertEqual(part.name, "სიფონი")
        XCTAssertTrue(part.hasValidBox)
        XCTAssertFalse(Part(id: "p2", name: "x", box: [500, 0, 400, 10]).hasValidBox)
        XCTAssertFalse(Part(id: "p3", name: "x", box: [0, 0, 1001, 10]).hasValidBox)
    }

    func testStepRoundTrips() throws {
        let step = Step(index: 1, title: "ნაბიჯი 1", text: "მოხსენი ქანჩი", focus: ["p1"], avoid: ["p4"])
        let decoded = try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step))
        XCTAssertEqual(decoded, step)
    }
    func testWorkerPresentationFieldsAndLegacySteps() throws {
        let payload = #"{"index":1,"title":"მოუშვი","text":"ხელით","focus":["p1"],"avoid":[],"markers":[{"part":"p1","label":"ქანჩი","tone":"brand"}],"arrows":[{"part":"p1","type":"rotate","dir":"ccw"}],"tools":["ხელთათმანი"],"warn":"ფრთხილად"}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(payload.utf8))
        XCTAssertEqual(step.arrows.first?.dir, "ccw")
        XCTAssertEqual(step.markers.first?.label, "ქანჩი")
        XCTAssertEqual(step.tools, ["ხელთათმანი"])
        XCTAssertEqual(step.warn, "ფრთხილად")
        XCTAssertEqual(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)), step)
        let old = #"{"index":1,"title":"x","text":"y","focus":[],"avoid":[]}"#
        let legacy = try JSONDecoder().decode(Step.self, from: Data(old.utf8))
        XCTAssertTrue(legacy.arrows.isEmpty)
        XCTAssertTrue(legacy.tools.isEmpty)
        XCTAssertNil(legacy.warn)
    }
    func testStepIconsDecodeAlongsideLegacyTools() throws {
        let old = #"{"index":1,"title":"x","text":"y","tools":["ტილო"]}"#
        let legacy = try JSONDecoder().decode(Step.self, from: Data(old.utf8))
        XCTAssertEqual(legacy.tools, ["ტილო"])
        XCTAssertNil(legacy.icon)
        XCTAssertNil(legacy.toolItems)

        let payload = #"{"index":1,"title":"x","text":"y","tools":["ტილო","ვედრო"],"icon":"clean","toolItems":[{"label":"ტილო","icon":"cloth"},{"label":"ვედრო","icon":null}]}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(payload.utf8))
        XCTAssertEqual(step.icon, "clean")
        XCTAssertEqual(step.tools, ["ტილო", "ვედრო"])
        XCTAssertEqual(step.toolItems, [StepTool(label: "ტილო", icon: "cloth"), StepTool(label: "ვედრო")])
        XCTAssertEqual(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)), step)
        let nulls = #"{"index":1,"title":"x","text":"y","icon":null,"toolItems":null}"#
        let empty = try JSONDecoder().decode(Step.self, from: Data(nulls.utf8))
        XCTAssertNil(empty.icon)
        XCTAssertNil(empty.toolItems)
    }
}
