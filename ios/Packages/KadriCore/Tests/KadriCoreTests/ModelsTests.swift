import XCTest
@testable import KadriCore

final class ModelsTests: XCTestCase {
    func testDiagnosticContinuationsDecodeAndFallback() throws {
        func decode(_ json: String) throws -> StepsContinuation {
            try JSONDecoder().decode(StepsContinuation.self, from: Data(json.utf8))
        }
        XCTAssertEqual(try decode(#"{"kind":"complete","cause":"cause","summary":"summary"}"#), .complete(cause: "cause", summary: "summary"))
        XCTAssertEqual(try decode(#"{"kind":"needs_answer","question":"q","options":["a","b"],"allowOther":true,"reason":null}"#),
                       .needsAnswer(question: "q", options: ["a", "b"], allowOther: true, reason: nil))
        XCTAssertEqual(try decode(#"{"kind":"needs_measurement","question":"q","unit":"mA","min":0,"max":500,"how":"h","reason":null}"#),
                       .needsMeasurement(question: "q", unit: "mA", min: 0, max: 500, how: "h", reason: nil))
        for json in [#"{"kind":"needs_measurement","question":"q","unit":"mA","how":"h","min":"bad"}"#, #"{"kind":"unknown"}"#, #"{"kind":"needs_answer","options":["a"]}"#,
                     #"{"kind":"needs_measurement","question":"q","unit":" ","how":"h"}"#, #"[]"#,
                     #"{"kind":"needs_answer","question":"q","options":["a","b"],"allowOther":"yes"}"#] {
            XCTAssertTrue(try decode(json).isComplete)
        }
    }

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

    // MARK: multi-photo

    private func continuation(_ json: String) throws -> StepsContinuation {
        try JSONDecoder().decode(StepsContinuation.self, from: Data(json.utf8))
    }

    func testContinuationDecoding() throws {
        XCTAssertEqual(try continuation(#"{"kind":"complete"}"#), .complete)
        XCTAssertEqual(try continuation(#"{"kind":"complete","prompt":null,"reason":null}"#), .complete)
        XCTAssertEqual(try continuation(#"{"kind":"needs_photo","prompt":"გადაიღე სიფონის შიგნითა მხარე","reason":"არ ჩანს."}"#),
                       .needsPhoto(prompt: "გადაიღე სიფონის შიგნითა მხარე", reason: "არ ჩანს."))
        XCTAssertEqual(try continuation(#"{"kind":"needs_photo","prompt":"გადაიღე"}"#), .needsPhoto(prompt: "გადაიღე", reason: ""))
        XCTAssertEqual(try continuation(#"{"kind":"needs_video","prompt":"x","reason":"y"}"#), .complete, "unknown kind")
        XCTAssertEqual(try continuation(#"{"kind":"needs_photo","prompt":"  ","reason":"y"}"#), .complete, "blank prompt")
        XCTAssertEqual(try continuation(#"{"kind":"needs_photo","prompt":null}"#), .complete)
        XCTAssertEqual(try continuation(#"{}"#), .complete)
        XCTAssertEqual(try continuation(#""needs_photo""#), .complete, "not an object")
    }

    func testSessionContextEncodesWireNames() throws {
        let context = SessionContext(round: 2, photoPrompt: "გადაიღე", doneSteps: ["დაკეტე წყალი", "ჩადგი ვედრო"], previousObject: "ნიჟარის სიფონი")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(context)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["round", "photoPrompt", "doneSteps", "previousObject", "answers"])
        XCTAssertEqual(json["round"] as? Int, 2)
        XCTAssertEqual(json["photoPrompt"] as? String, "გადაიღე")
        XCTAssertEqual(json["doneSteps"] as? [String], ["დაკეტე წყალი", "ჩადგი ვედრო"])
        XCTAssertEqual(json["previousObject"] as? String, "ნიჟარის სიფონი")
        XCTAssertEqual(try JSONDecoder().decode(SessionContext.self, from: JSONEncoder().encode(context)), context)

        let bare = SessionContext(round: 3, photoPrompt: "p", doneSteps: [])
        let bareJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        XCTAssertNil(bareJSON["previousObject"], "nil previousObject is omitted")
    }

    func testDoneEventDefaultsToComplete() {
        XCTAssertEqual(StepEvent.done(nil), .done(nil, continuation: .complete))
    }
}
