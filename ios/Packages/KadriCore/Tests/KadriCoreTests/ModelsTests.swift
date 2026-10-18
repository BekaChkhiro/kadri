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

    func testHandsDecodeAndIgnoreUnknownGestures() throws {
        let payload = #"{"index":1,"title":"x","text":"y","hands":[{"part":"p1","grip":"hold","hand":"left","byHandOnly":false},{"part":"p2","grip":"turn","hand":"right","byHandOnly":true},{"part":"p3","grip":"future","hand":"both","byHandOnly":true},{"part":"p4","grip":"hold","hand":"future","byHandOnly":true}]}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(payload.utf8))
        XCTAssertEqual(step.hands, [
            .init(part: "p1", grip: "hold", hand: "left", byHandOnly: false),
            .init(part: "p2", grip: "turn", hand: "right", byHandOnly: true)
        ])
        XCTAssertEqual(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)), step)
        for json in [#"{"index":1,"title":"x","text":"y"}"#,
                     #"{"index":1,"title":"x","text":"y","hands":null}"#] {
            XCTAssertNil(try JSONDecoder().decode(Step.self, from: Data(json.utf8)).hands)
        }
    }

    func testCheckPhotoAndSixAnswerOptionsDecode() throws {
        let decoder = JSONDecoder()
        let photo = Data(#"{"kind":"needs_check_photo","prompt":"ახლოდან","reason":"შევამოწმებ"}"#.utf8)
        XCTAssertEqual(try decoder.decode(StepsContinuation.self, from: photo), .needsCheckPhoto(prompt: "ახლოდან", reason: "შევამოწმებ"))
        let answer = Data(#"{"kind":"needs_answer","question":"q","options":["a","b","c","d","არ ვიცი","ფოტოს გაჩვენებ"],"allowOther":true}"#.utf8)
        guard case .needsAnswer(_, let options, let allowOther, _) = try decoder.decode(StepsContinuation.self, from: answer) else { return XCTFail("expected answer") }
        XCTAssertEqual(options.count, 6)
        XCTAssertTrue(allowOther)
        let legacy = SessionContext(round: 2, photoPrompt: "photo", doneSteps: [])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        XCTAssertNil(json["checkPhotos"])
        XCTAssertNil(json["checkPrompt"])
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

    func testToolCardsAndActionsDecodeAndRoundTrip() throws {
        let payload = #"{"index":1,"title":"x","text":"y","toolCards":[{"id":"ph2","size":"PH2","why":"ჯვარედინი ჭანჭიკი","notThis":{"id":"flat_small","reason":"ჭრილს დააზიანებს"}},{"id":"towel","size":null,"why":"წყალი წვეთავს","notThis":null}],"actions":[{"part":"p1","kind":"rotate_ccw","amount":"½","order":null},{"part":"p2","kind":"tighten_order","amount":"hand_tight_plus_quarter","order":["p2","p3","p4"]}]}"#
        let step = try JSONDecoder().decode(Step.self, from: Data(payload.utf8))
        XCTAssertEqual(step.toolCards, [
            StepToolCard(id: "ph2", size: "PH2", why: "ჯვარედინი ჭანჭიკი",
                         notThis: .init(id: "flat_small", reason: "ჭრილს დააზიანებს")),
            StepToolCard(id: "towel", why: "წყალი წვეთავს"),
        ])
        XCTAssertEqual(step.actions, [
            StepAction(part: "p1", kind: "rotate_ccw", amount: "½"),
            StepAction(part: "p2", kind: "tighten_order", amount: "hand_tight_plus_quarter", order: ["p2", "p3", "p4"]),
        ])
        XCTAssertEqual(try JSONDecoder().decode(Step.self, from: JSONEncoder().encode(step)), step)

        let old = #"{"index":1,"title":"x","text":"y","tools":["ტილო"]}"#
        let legacy = try JSONDecoder().decode(Step.self, from: Data(old.utf8))
        XCTAssertNil(legacy.toolCards)
        XCTAssertNil(legacy.actions)
        let nulls = #"{"index":1,"title":"x","text":"y","toolCards":null,"actions":null}"#
        let empty = try JSONDecoder().decode(Step.self, from: Data(nulls.utf8))
        XCTAssertNil(empty.toolCards)
        XCTAssertNil(empty.actions)
    }

    func testToolCatalog() {
        XCTAssertEqual(ToolCatalog.ids.count, 32)
        XCTAssertEqual(Set(ToolCatalog.ids).count, 32)
        XCTAssertEqual(Set(ToolCatalog.names.keys), Set(ToolCatalog.ids))
        for id in ToolCatalog.ids {
            XCTAssertFalse(ToolCatalog.name(id)?.isEmpty ?? true, id)
        }
        XCTAssertEqual(ToolCatalog.ids.first, "ph1")
        XCTAssertEqual(ToolCatalog.ids.last, "spudger")
        XCTAssertEqual(ToolCatalog.name("ph2"), "ჯვარედინი სახრახნისი PH2")
        XCTAssertNil(ToolCatalog.name("chainsaw"))
        XCTAssertEqual(ToolCatalog.assetName("ph2"), "tool-ph2")
    }

    func testToolSizeEvidenceAndLegacyDefaults() throws {
        let json = #"{"id":"open_wrench","size":"10 მმ","why":"ქანჩისთვის","sizeSource":"typical","fitCheck":"მჭიდროდ უნდა მოერგოს","alternatives":["11 მმ"]}"#
        let card = try JSONDecoder().decode(StepToolCard.self, from: Data(json.utf8))
        XCTAssertEqual(card.sizeSource, "typical")
        XCTAssertEqual(card.fitCheck, "მჭიდროდ უნდა მოერგოს")
        XCTAssertEqual(card.alternatives, ["11 მმ"])
        XCTAssertEqual(try JSONDecoder().decode(StepToolCard.self, from: JSONEncoder().encode(card)), card)
        for source in ["seen", "model"] {
            let payload = json.replacingOccurrences(of: "typical", with: source)
            XCTAssertEqual(try JSONDecoder().decode(StepToolCard.self, from: Data(payload.utf8)).sizeSource, source)
        }
        for payload in [#"{"id":"ph2","size":"PH2","why":"ხრახნისთვის"}"#,
                        #"{"id":"ph2","size":"PH2","why":"ხრახნისთვის","sizeSource":null,"fitCheck":null,"alternatives":null}"#] {
            let legacy = try JSONDecoder().decode(StepToolCard.self, from: Data(payload.utf8))
            XCTAssertEqual(legacy.sizeSource, "typical")
            XCTAssertNil(legacy.fitCheck)
            XCTAssertEqual(legacy.alternatives, [])
            XCTAssertEqual(legacy, StepToolCard(id: "ph2", size: "PH2", why: "ხრახნისთვის"))
        }
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
