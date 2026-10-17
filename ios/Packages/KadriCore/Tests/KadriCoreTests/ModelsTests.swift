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
}
