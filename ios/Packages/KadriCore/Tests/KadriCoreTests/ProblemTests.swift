import XCTest
@testable import KadriCore

private func evidence(_ id: String = "photo1", role: ProblemPhoto.Role = .detail) -> ProblemPhoto {
    .init(id: id, image: Data([0xff, 0xd8, UInt8(id.count)]), note: "ჩემი ფოტო", role: role)
}
private func response(_ photos: [ProblemPhoto], steps: Bool = true, kind: ProblemNext.Kind = .verify, sequence: Int = 0) -> ProblemResult {
    .init(summary: "ერთი შეერთება სხვადასხვა კუთხიდან", observations: photos.map { .init(photoId: $0.id, detail: "შეერთება", relevance: "relevant") },
          components: [.init(id: "joint", name: "შეერთება", views: photos.map { .init(photoId: $0.id, box: [100, 100, 400, 400]) })], links: [],
          steps: steps ? [.init(id: "step\(sequence)", title: "შეამოწმე", text: "დააკვირდი შეერთებას", photoId: photos[0].id, componentIds: ["joint"], arrow: .init(type: "move", dir: "up"))] : [],
          next: .init(kind: kind, prompt: "რა შეიცვალა?", reason: "საჭიროა გადამოწმება"))
}
private struct ProblemStub: KadriAPI {
    var handler: @Sendable (ProblemRequest) async throws -> ProblemResult
    func problem(_ request: ProblemRequest) async throws -> ProblemResult { try await handler(request) }
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult { throw URLError(.unsupportedURL) }
    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> { AsyncThrowingStream { $0.finish() } }
}

final class ProblemTests: XCTestCase {
    func testJSONTransportSendsAllImagesAndContext() async throws {
        let photos = [evidence("wide", role: .overview), evidence("close"), evidence("after", role: .after)]
        let payload = ProblemRequest(problem: "ჟონავს", photos: photos, history: [.init(stepId: "s", title: "მოვუჭირე", photoId: "close", outcome: .unchanged)], answers: [.init(question: "საიდან?", answer: "ქვემოდან")], provider: .gemini)
        let captured = Locked<Data?>(nil)
        let data = try JSONEncoder().encode(response(photos))
        let url = MockURLProtocol.register { request, body in
            XCTAssertEqual(request.url?.path, "/ai/problem")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            captured.value = body
            return .init(chunks: [data])
        }
        let client = KadriClient(config: APIConfig(baseURL: url), auth: StaticToken(token: "tok"), session: MockURLProtocol.session())
        _ = try await client.problem(payload)
        let sent = try JSONDecoder().decode(ProblemRequest.self, from: XCTUnwrap(captured.value))
        XCTAssertEqual(sent, payload)
        XCTAssertEqual(sent.photos.map(\.image), photos.map(\.image))
    }
    func testRejectsComponentOnWrongPhotoAndInventedReferences() throws {
        let photos = [evidence(), evidence("photo2")]
        let base = response(photos)
        let wrong = ProblemResult(summary: base.summary, observations: base.observations,
                                  components: [.init(id: "joint", name: "ქანჩი", views: [.init(photoId: "photo2", box: [0, 0, 500, 500])])], links: [], steps: base.steps, next: base.next)
        XCTAssertThrowsError(try wrong.validate(for: .init(problem: "p", photos: photos)))
        let invented = ProblemResult(summary: base.summary, observations: base.observations, components: base.components,
                                     links: [.init(fromId: "joint", toId: "missing", relation: .connected, evidencePhotoIds: ["photo1"], reason: "r")], steps: base.steps, next: base.next)
        XCTAssertThrowsError(try invented.validate(for: .init(problem: "p", photos: photos)))
    }
    func testResolvedRequiresUserConfirmationAndPerformedAction() throws {
        let photos = [evidence()]
        let resolved = response(photos, steps: false, kind: .resolved)
        XCTAssertThrowsError(try resolved.validate(for: .init(problem: "p", photos: photos)))
        XCTAssertThrowsError(try resolved.validate(for: .init(problem: "p", photos: photos, resolutionConfirmed: true)))
        XCTAssertNoThrow(try resolved.validate(for: .init(problem: "p", photos: photos, history: [.init(stepId: "s", title: "s", photoId: "photo1", outcome: .done)], resolutionConfirmed: true)))
    }
    @MainActor func testFailedOutcomeReplansAndRetryDoesNotDuplicateHistory() async {
        let requests = Locked<[ProblemRequest]>([])
        let model = ProblemSessionModel(api: ProblemStub { request in
            requests.value.append(request)
            if requests.value.count == 2 { throw URLError(.notConnectedToInternet) }
            return response(request.photos, steps: request.history.isEmpty, kind: request.history.isEmpty ? .verify : .needsAnswer)
        })
        model.problem = "ჟონავს"; model.addPhoto(evidence())
        await model.submit()
        XCTAssertNotNil(model.currentStep)
        await model.markCurrentStep(outcome: .unable, note: "არ მოძრაობს")
        XCTAssertEqual(model.phase, .error)
        XCTAssertNotNil(model.result)
        XCTAssertNil(model.currentStep)
        XCTAssertNil(model.continuation)
        await model.retry()
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(requests.value[1].history, requests.value[2].history)
        XCTAssertEqual(model.continuation?.kind, .needsAnswer)
    }
    @MainActor func testBeforeAfterEvidenceAndExplicitResolution() async {
        let requests = Locked<[ProblemRequest]>([])
        let model = ProblemSessionModel(api: ProblemStub { request in
            requests.value.append(request)
            return response(request.photos, steps: request.history.isEmpty, kind: request.resolutionConfirmed ? .resolved : .verify)
        })
        model.problem = "ჟონავს"; model.addPhoto(evidence())
        await model.submit(); await model.markCurrentStep(outcome: .done)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.continuation?.kind, .verify)
        XCTAssertFalse(model.removePhoto(id: "photo1"))
        XCTAssertTrue(model.addPhoto(evidence("after", role: .after)))
        XCTAssertTrue(model.updatePhoto(id: "after", note: "შესრულების შემდეგ", role: .after))
        await model.submit()
        XCTAssertEqual(requests.value.last?.photos.map(\.role), [.detail, .after])
        XCTAssertEqual(requests.value.last?.previousComponents.first?.id, "joint")
        XCTAssertFalse(model.updatePhoto(id: "after", note: "ახალი", role: .detail))
        await model.confirmResolution()
        XCTAssertEqual(model.phase, .resolved)
        XCTAssertEqual(requests.value.last?.resolutionConfirmed, true)
    }
    @MainActor func testPhotoLimitDoesNotBecomeSuccess() async {
        let model = ProblemSessionModel(api: ProblemStub { request in response(request.photos, steps: false, kind: .needsPhoto) })
        model.problem = "p"
        for number in 0..<5 { XCTAssertTrue(model.addPhoto(evidence("p\(number)"))) }
        XCTAssertFalse(model.addPhoto(evidence("sixth")))
        await model.submit()
        XCTAssertEqual(model.photos.count, 5)
        XCTAssertEqual(model.phase, .unresolved)
        XCTAssertEqual(model.continuation?.kind, .unresolved)
    }
    @MainActor func testAnswerLimitDoesNotBecomeSuccess() async {
        let model = ProblemSessionModel(api: ProblemStub { request in response(request.photos, steps: false, kind: .needsAnswer) })
        model.problem = "p"; model.addPhoto(evidence()); await model.submit()
        for _ in 0..<12 { await model.answer("არ ვიცი") }
        XCTAssertEqual(model.answers.count, 12)
        XCTAssertEqual(model.phase, .unresolved)
        await model.answer("კიდევ")
        XCTAssertEqual(model.answers.count, 12)
    }
    @MainActor func testInitialFailureKeepsDraftEditableAndRetryUsesEdits() async {
        let calls = Locked<[ProblemRequest]>([])
        let model = ProblemSessionModel(api: ProblemStub { request in
            calls.value.append(request)
            if calls.value.count == 1 { throw URLError(.notConnectedToInternet) }
            return response(request.photos)
        })
        model.problem = "ძველი აღწერა"; model.addPhoto(evidence())
        await model.submit()
        XCTAssertFalse(model.hasSubmitted)
        XCTAssertTrue(model.canEditPhoto(id: "photo1"))
        XCTAssertTrue(model.updatePhoto(id: "photo1", note: "დაზუსტებული", role: .overview))
        model.problem = "ახალი აღწერა"
        await model.retry()
        XCTAssertEqual(calls.value.last?.problem, "ახალი აღწერა")
        XCTAssertEqual(calls.value.last?.photos.first?.note, "დაზუსტებული")
        XCTAssertTrue(model.hasSubmitted)
        XCTAssertFalse(model.canEditPhoto(id: "photo1"))
    }
    func testRejectsReplayedStepsAndUncertainAssociations() {
        let photos = [evidence()]
        let base = response(photos)
        let request = ProblemRequest(problem: "p", photos: photos, history: [.init(stepId: "step0", title: "სცადე", photoId: "photo1", outcome: .unable)])
        XCTAssertThrowsError(try base.validate(for: request))
        let other = ProblemComponent(id: "other", name: "მეორე ნაწილი", views: [.init(photoId: "photo1", box: [500, 500, 800, 800])])
        let uncertain = ProblemResult(summary: base.summary, observations: base.observations, components: base.components + [other], links: [.init(fromId: "joint", toId: "other", relation: .uncertain, evidencePhotoIds: ["photo1"], reason: "კავშირი არ ჩანს")], steps: base.steps, next: base.next)
        XCTAssertThrowsError(try uncertain.validate(for: .init(problem: "p", photos: photos)))
    }
    @MainActor func testHistoryLimitEndsUnresolvedWithoutTruncatingEvidence() async {
        let model = ProblemSessionModel(api: ProblemStub { request in
            response(request.photos, steps: request.history.count < 30, kind: request.history.count < 30 ? .verify : .unresolved, sequence: request.history.count)
        })
        model.problem = "p"; model.addPhoto(evidence()); await model.submit()
        for _ in 0..<30 { await model.markCurrentStep(outcome: .unchanged) }
        XCTAssertEqual(model.history.count, 30)
        XCTAssertEqual(model.phase, .unresolved)
        XCTAssertNil(model.currentStep)
        XCTAssertEqual(model.photos.count, 1)
    }
    @MainActor func testDirectModelInputsCannotPoisonFutureRequestsWithOversizeText() async {
        let requests = Locked<[ProblemRequest]>([])
        let model = ProblemSessionModel(api: ProblemStub { request in
            requests.value.append(request)
            if requests.value.count == 2 { throw URLError(.notConnectedToInternet) }
            return response(request.photos, steps: request.history.isEmpty, kind: request.history.isEmpty ? .verify : .needsAnswer)
        })
        let long = String(repeating: "👩‍🔧", count: 1100)
        model.problem = long
        model.addPhoto(.init(id: "photo1", image: Data([1]), note: long))
        XCTAssertLessThanOrEqual(model.photos[0].note.unicodeScalars.count, 300)
        model.updatePhoto(id: "photo1", note: long + "ბოლო", role: .detail)
        await model.submit()
        await model.markCurrentStep(outcome: .unable, note: long)
        XCTAssertEqual(model.phase, .error)
        await model.retry()
        await model.answer(long)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.answers.count, 1)
        for request in requests.value {
            XCTAssertLessThanOrEqual(request.problem.unicodeScalars.count, 1000)
            XCTAssertTrue(request.photos.allSatisfy { $0.note.unicodeScalars.count <= 300 })
            XCTAssertTrue(request.history.allSatisfy { $0.note.unicodeScalars.count <= 300 })
            XCTAssertTrue(request.answers.allSatisfy { $0.answer.unicodeScalars.count <= 500 })
        }
        XCTAssertEqual(requests.value[1].history, requests.value[2].history)
        XCTAssertTrue(model.problem.allSatisfy { String($0) == "👩‍🔧" })
    }
    func testTransportUsesAITimeoutWithoutAutomaticReplay() async {
        let calls = Locked(0)
        let url = MockURLProtocol.register { request, _ in
            calls.value += 1
            XCTAssertEqual(request.timeoutInterval, 75)
            return .init(chunks: [], failure: URLError(.timedOut))
        }
        let api = KadriClient(config: APIConfig(baseURL: url), auth: nil, session: MockURLProtocol.session())
        do {
            _ = try await api.problem(.init(problem: "p", photos: [evidence()]))
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual(error as? SessionError, .timeout) }
        XCTAssertEqual(calls.value, 1)
    }
    func testTransportCancellationStopsInFlightRequest() async {
        let started = expectation(description: "request started")
        let stopped = expectation(description: "request cancelled")
        let gate = DispatchSemaphore(value: 0)
        let url = MockURLProtocol.register { _, _ in
            started.fulfill()
            return .init(chunks: [Data("{}".utf8)], beforeChunk: { _ in _ = gate.wait(timeout: .now() + 5) }, onStop: { stopped.fulfill() })
        }
        let api = KadriClient(config: APIConfig(baseURL: url), auth: nil, session: MockURLProtocol.session())
        let task = Task { try await api.problem(.init(problem: "p", photos: [evidence()])) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await fulfillment(of: [stopped], timeout: 2)
        gate.signal()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { }
    }
    @MainActor func testCancellationIgnoresLateResultsThenRetryWorks() async {
        let calls = Locked(0)
        let model = ProblemSessionModel(api: ProblemStub { request in
            calls.value += 1
            if calls.value == 1 { try? await Task.sleep(for: .milliseconds(80)) }
            return response(request.photos, steps: false, kind: .needsAnswer)
        })
        model.problem = "p"; model.addPhoto(evidence())
        let old = Task { await model.submit() }
        while calls.value == 0 { await Task.yield() }
        model.cancel()
        XCTAssertEqual(model.phase, .draft)
        await model.retry()
        await old.value
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.continuation?.kind, .needsAnswer)
        XCTAssertEqual(calls.value, 2)
    }
}
