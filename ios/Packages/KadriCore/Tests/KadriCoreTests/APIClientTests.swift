import XCTest
@testable import KadriCore

final class APIClientTests: XCTestCase {
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])

    private func client(token: String? = "tok", _ handler: @escaping MockURLProtocol.Handler) -> KadriClient {
        let url = MockURLProtocol.register(handler)
        return KadriClient(config: APIConfig(baseURL: url), auth: token.map { StaticToken(token: $0) }, session: MockURLProtocol.session())
    }

    private func partsError(_ reply: MockURLProtocol.Reply) async -> SessionError? {
        do {
            _ = try await client { _, _ in reply }.parts(keyframe: jpeg, instructions: "x")
            return nil
        } catch {
            return error as? SessionError
        }
    }

    func testGeminiProviderIsSentInBothRequests() async throws {
        let seen = Locked<[Data]>([])
        let api = client { request, body in
            seen.value.append(body)
            if request.url?.path == "/ai/parts" { return .json(200, #"{"object":"o","parts":[]}"#) }
            return .json(200, "event: done\ndata: {}\n\n")
        }
        _ = try await api.parts(keyframe: jpeg, instructions: "x", context: nil, provider: .gemini)
        for try await _ in api.steps(object: "o", parts: [], instructions: "x", context: nil, provider: .gemini) {}
        XCTAssertTrue(String(decoding: seen.value[0], as: UTF8.self).contains("name=\"provider\"\r\n\r\ngemini"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.value[1]) as? [String: Any])
        XCTAssertEqual(body["provider"] as? String, "gemini")
    }

    func testAIRequestsRetryLostConnectionAndTimeoutOnce() async throws {
        for path in ["/ai/parts", "/ai/steps"] {
            for code in [URLError.networkConnectionLost, .timedOut] {
                let requests = Locked<[(URLRequest, Data)]>([])
                let api = client { request, body in
                    requests.value.append((request, body))
                    if requests.value.count == 1 { return .init(chunks: [], failure: URLError(code)) }
                    return .json(200, path == "/ai/parts" ? #"{"object":"o","parts":[]}"# : "event: done\ndata: {}\n\n")
                }
                if path == "/ai/parts" {
                    let result = try await api.parts(keyframe: jpeg, instructions: "x")
                    XCTAssertEqual(result.object, "o")
                } else {
                    var events: [StepEvent] = []
                    for try await event in api.steps(object: "o", parts: [], instructions: "x") { events.append(event) }
                    XCTAssertEqual(events, [.done(StepsUsage())])
                }
                XCTAssertEqual(requests.value.count, 2)
                XCTAssertEqual(requests.value.map { $0.0.url?.path }, [path, path])
                XCTAssertEqual(requests.value.first?.1, requests.value.last?.1)
                XCTAssertEqual(requests.value.last?.0.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
            }
        }
    }

    func testAIRequestsStopAfterSecondTransportFailureAndDoNotRetryOffline() async {
        for path in ["/ai/parts", "/ai/steps"] {
            for code in [URLError.networkConnectionLost, .timedOut, .notConnectedToInternet, .cancelled] {
                let calls = Locked(0)
                let api = client { _, _ in
                    calls.value += 1
                    return .init(chunks: [], failure: URLError(code))
                }
                do {
                    if path == "/ai/parts" {
                        _ = try await api.parts(keyframe: jpeg, instructions: "x")
                    } else {
                        for try await _ in api.steps(object: "o", parts: [], instructions: "x") {}
                    }
                    XCTFail("expected transport failure")
                } catch {
                    XCTAssertEqual(error as? SessionError, SessionError(URLError(code)))
                }
                XCTAssertEqual(calls.value, code == .networkConnectionLost || code == .timedOut ? 2 : 1)
            }
        }
    }

    func testAIRequestsDoNotRetryAfterResponseStarted() async {
        for path in ["/ai/parts", "/ai/steps"] {
            for code in [URLError.networkConnectionLost, .timedOut] {
                ResponseFailureProtocol.calls.value = 0
                ResponseFailureProtocol.failure.value = code
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ResponseFailureProtocol.self]
                let session = URLSession(configuration: configuration)
                defer { session.invalidateAndCancel() }
                let api = KadriClient(config: APIConfig(baseURL: URL(string: "https://response.test")!), auth: nil, session: session)
                var events: [StepEvent] = []
                do {
                    if path == "/ai/parts" {
                        _ = try await api.parts(keyframe: jpeg, instructions: "x")
                    } else {
                        for try await event in api.steps(object: "o", parts: [], instructions: "x") { events.append(event) }
                    }
                    XCTFail("expected transport failure")
                } catch {
                    XCTAssertEqual(error as? SessionError, SessionError(URLError(code)))
                }
                XCTAssertEqual(ResponseFailureProtocol.calls.value, 1)
                if path == "/ai/steps" { XCTAssertEqual(events.count, 1, "must not replay a delivered step") }
            }
        }
    }

    // MARK: parts

    func testPartsSendsMultipartWithBearerAndDecodesResult() async throws {
        let seen = Locked<(URLRequest, Data)?>(nil)
        let api = client { request, body in
            seen.value = (request, body)
            return .json(200, """
            {"object":"ნიჟარის სიფონი","parts":[{"id":"p1","name":"თხილი","box":[100,200,300,400]}],
             "model":"gpt-6-astra","usage":{"input_tokens":10,"output_tokens":5},"costUsd":0.01,"latencyMs":6612.4}
            """)
        }
        let result = try await api.parts(keyframe: jpeg, instructions: "სიფონი ჟონავს")
        XCTAssertEqual(result, PartsResult(object: "ნიჟარის სიფონი", parts: [Part(id: "p1", name: "თხილი", box: [100, 200, 300, 400])], latencyMs: 6612))

        let (request, body) = try XCTUnwrap(seen.value)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/ai/parts")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"image\"; filename=\"keyframe.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(text.contains("name=\"instructions\"\r\n\r\nსიფონი ჟონავს\r\n"))
        XCTAssertTrue(text.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertNotNil(body.range(of: jpeg))
        XCTAssertFalse(text.contains("name=\"context\""), "round 1 sends no context")
    }

    func testPartsSendsContextAsJSONField() async throws {
        let seen = Locked<Data?>(nil)
        let api = client { _, body in
            seen.value = body
            return .json(200, #"{"object":"მოხსნილი სიფონი","parts":[]}"#)
        }
        let context = SessionContext(round: 2, photoPrompt: "გადაიღე შიგნითა მხარე", doneSteps: ["დაკეტე წყალი"], previousObject: "ნიჟარის სიფონი")
        _ = try await api.parts(keyframe: jpeg, instructions: "ჟონავს", context: context)

        let text = String(decoding: try XCTUnwrap(seen.value), as: UTF8.self)
        let marker = "name=\"context\"\r\n\r\n"
        let start = try XCTUnwrap(text.range(of: marker)).upperBound
        let end = try XCTUnwrap(text[start...].range(of: "\r\n")).lowerBound
        XCTAssertEqual(try JSONDecoder().decode(SessionContext.self, from: Data(text[start..<end].utf8)), context)
    }

    func testPartsWithoutAuthSendsNoAuthorization() async throws {
        let header = Locked<String?>("unset")
        let api = client(token: nil) { request, _ in
            header.value = request.value(forHTTPHeaderField: "Authorization")
            return .json(200, #"{"object":"o","parts":[]}"#)
        }
        let result = try await api.parts(keyframe: jpeg, instructions: "x")
        XCTAssertEqual(result.parts, [])
        XCTAssertNil(result.latencyMs)
        XCTAssertNil(header.value)
    }

    func testParts401IsUnauthorized() async {
        let error = await partsError(.json(401, #"{"error":{"code":"unauthorized","message":"ავტორიზაცია საჭიროა"}}"#))
        XCTAssertEqual(error, .unauthorized)
    }

    func testParts429DailyLimitKeepsGeorgianMessage() async {
        let error = await partsError(.json(429, #"{"error":{"code":"daily_limit","message":"დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ"}}"#, headers: ["Retry-After": "3600"]))
        XCTAssertEqual(error, .server(code: "daily_limit", message: "დღევანდელი ლიმიტი ამოიწურა, სცადეთ ხვალ"))
    }

    func testParts502And504() async {
        let upstream = await partsError(.json(502, #"{"error":{"code":"ai_upstream","message":"AI სერვისი დროებით მიუწვდომელია, სცადე თავიდან"}}"#))
        XCTAssertEqual(upstream, .server(code: "ai_upstream", message: "AI სერვისი დროებით მიუწვდომელია, სცადე თავიდან"))
        let timeout = await partsError(.json(504, #"{"error":{"code":"ai_timeout","message":"…"}}"#))
        XCTAssertEqual(timeout, .timeout)
    }

    func testPartsNetworkFailureAndBadBody() async {
        let offline = await partsError(MockURLProtocol.Reply(chunks: [], failure: URLError(.notConnectedToInternet)))
        XCTAssertEqual(offline, .network)
        let timedOut = await partsError(MockURLProtocol.Reply(chunks: [], failure: URLError(.timedOut)))
        XCTAssertEqual(timedOut, .timeout)
        let garbage = await partsError(.json(200, "<html>"))
        XCTAssertEqual(garbage, .server(code: "bad_response", message: ""))
    }

    func testAnswerRequestCapabilitiesContextAndImage() async throws {
        let seen = Locked<Data?>(nil)
        let api = client { _, body in
            seen.value = body
            return .init(headers: ["Content-Type": "text/event-stream"], chunks: [Data("event: done\ndata: {}\n\n".utf8)])
        }
        let answer = SessionAnswer(question: "რამდენი?", answer: "30", unit: "mA")
        let context = SessionContext(round: 1, photoPrompt: "", doneSteps: ["გაზომე"], answers: [answer], checkPhotos: 1, checkPrompt: "გადაიღე ახლოდან")
        for try await _ in api.steps(object: "ობიექტი", parts: parts, instructions: "შეამოწმე", image: jpeg, context: context) {}
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(seen.value)) as? [String: Any])
        XCTAssertEqual(json["capabilities"] as? [String], ["needs_answer", "needs_measurement", "summary", "tools_v2", "check_photo", "arrows_v2"])
        XCTAssertEqual(json["image"] as? String, jpeg.base64EncodedString())
        let bodyContext = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertNil(bodyContext["photoPrompt"])
        XCTAssertEqual(bodyContext["checkPhotos"] as? Int, 1)
        XCTAssertEqual(bodyContext["checkPrompt"] as? String, "გადაიღე ახლოდან")
        XCTAssertEqual(bodyContext["round"] as? Int, 1)
        XCTAssertEqual((bodyContext["answers"] as? [[String: String]])?.first?["unit"], "mA")
        XCTAssertEqual(try JSONDecoder().decode(SessionContext.self, from: JSONSerialization.data(withJSONObject: bodyContext)), context)
    }

    // MARK: steps

    private let stepsStream = """
    : comment\n\
    event: step\n\
    data: {"index":0,"title":"წყლის გადაკეტვა","text":"დაკეტე ონკანი.","focus":["p1"],"avoid":[],"markers":[],"arrows":[],"tools":[],"warn":null}\n\
    \n\
    event: step\r\n\
    data: {"index":1,"title":"თხილის მოშვება","text":"მოატრიალე საათის ისრის საწინააღმდეგოდ.","focus":["p2"],"avoid":["p1"],"markers":[],"arrows":[],"tools":["ქანჩი"],"warn":"წყალი დაიღვრება"}\r\n\
    \r\n\
    event: done\n\
    data: {"unknownParts":[],"usage":{"input_tokens":1200,"output_tokens":300,"output_tokens_details":{"reasoning_tokens":40}},"costUsd":0.027,"latencyMs":5321,"firstStepMs":4500,"model":"gpt-6-astra"}\n\
    \n
    """

    private let parts = [Part(id: "p1", name: "ონკანი", box: [0, 0, 10, 10]), Part(id: "p2", name: "თხილი", box: [10, 10, 20, 20])]

    func testStepsStreamsSplitChunksInOrderAndFirstStepArrivesBeforeDone() async throws {
        // Cut mid-"event:", mid-JSON (inside a Georgian multibyte char), and between CR and LF.
        let bytes = Array(stepsStream.utf8)
        let midGeorgian = try XCTUnwrap(bytes.firstIndex(of: 0xE1)) + 1
        let crlf = try XCTUnwrap(bytes.firstIndex(of: 0x0D)) + 1
        let doneStart = stepsStream.utf8.distance(from: stepsStream.startIndex, to: try XCTUnwrap(stepsStream.range(of: "event: done")).lowerBound)
        let pieces = chunks(stepsStream, at: [3, 14, midGeorgian, crlf, doneStart, doneStart + 9])
        let doneChunk = try XCTUnwrap(pieces.firstIndex { String(decoding: $0, as: UTF8.self).hasPrefix("event: d") })

        let firstStepSeen = DispatchSemaphore(value: 0)
        let heldDoneUntilStep = Locked(false)
        let requestBody = Locked<Data?>(nil)
        let api = client { _, body in
            requestBody.value = body
            return MockURLProtocol.Reply(headers: ["Content-Type": "text/event-stream"], chunks: pieces) { i in
                if i == doneChunk { heldDoneUntilStep.value = firstStepSeen.wait(timeout: .now() + 5) == .success }
            }
        }

        var events: [StepEvent] = []
        for try await event in api.steps(object: "სიფონი", parts: parts, instructions: "ჟონავს") {
            if events.isEmpty { firstStepSeen.signal() }
            events.append(event)
        }

        XCTAssertTrue(heldDoneUntilStep.value, "the first step must be delivered before the server sends done")
        XCTAssertEqual(events, [
            .step(Step(index: 0, title: "წყლის გადაკეტვა", text: "დაკეტე ონკანი.", focus: ["p1"])),
            .step(Step(index: 1, title: "თხილის მოშვება", text: "მოატრიალე საათის ისრის საწინააღმდეგოდ.", focus: ["p2"], avoid: ["p1"], tools: ["ქანჩი"], warn: "წყალი დაიღვრება")),
            .done(StepsUsage(inputTokens: 1200, outputTokens: 300, reasoningTokens: 40, costUsd: 0.027, latencyMs: 5321)),
        ])

        let json = try JSONSerialization.jsonObject(with: try XCTUnwrap(requestBody.value)) as? [String: Any]
        XCTAssertEqual(json?["object"] as? String, "სიფონი")
        XCTAssertEqual(json?["instructions"] as? String, "ჟონავს")
        XCTAssertEqual((json?["parts"] as? [[String: Any]])?.map { $0["id"] as? String }, ["p1", "p2"])
        XCTAssertNil(json?["image"])
        XCTAssertNil(json?["context"], "round 1 sends no context")
    }

    func testStepsSendsContextAndParsesContinuation() async throws {
        let seen = Locked<Data?>(nil)
        let api = client { _, body in
            seen.value = body
            return MockURLProtocol.Reply(chunks: [Data("""
            event: done\ndata: {"unknownParts":[],"costUsd":0.07,"continuation":{"kind":"needs_photo","prompt":"გადაიღე მოხსნილი სიფონი","reason":"შიგნით არ ჩანს."}}\n\n
            """.utf8)])
        }
        let context = SessionContext(round: 2, photoPrompt: "გადაიღე", doneSteps: ["ა", "ბ"], previousObject: "სიფონი")
        var events: [StepEvent] = []
        for try await event in api.steps(object: "o", parts: parts, instructions: "i", context: context) { events.append(event) }
        XCTAssertEqual(events, [.done(StepsUsage(costUsd: 0.07), continuation: .needsPhoto(prompt: "გადაიღე მოხსნილი სიფონი", reason: "შიგნით არ ჩანს."))])

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(seen.value)) as? [String: Any])
        let sent = try JSONSerialization.data(withJSONObject: try XCTUnwrap(json["context"]))
        XCTAssertEqual(try JSONDecoder().decode(SessionContext.self, from: sent), context)
    }

    func testDoneWithCompleteOrOddContinuation() async {
        let complete = await collect(MockURLProtocol.Reply(chunks: [Data("event: done\ndata: {\"continuation\":{\"kind\":\"complete\",\"prompt\":null,\"reason\":null}}\n\n".utf8)]))
        XCTAssertEqual(complete.0, [.done(StepsUsage(), continuation: .complete)])
        let odd = await collect(MockURLProtocol.Reply(chunks: [Data("event: done\ndata: {\"costUsd\":1,\"continuation\":\"later\"}\n\n".utf8)]))
        XCTAssertEqual(odd.0, [.done(StepsUsage(costUsd: 1), continuation: .complete)], "a malformed continuation keeps the usage")
    }

    func testStepsSendsImageAndJSONHeaders() async throws {
        let seen = Locked<(URLRequest, Data)?>(nil)
        let api = client { request, body in
            seen.value = (request, body)
            return MockURLProtocol.Reply(chunks: [Data("event: done\ndata: {}\n\n".utf8)])
        }
        var events: [StepEvent] = []
        for try await event in api.steps(object: "o", parts: parts, instructions: "i", image: jpeg) { events.append(event) }
        XCTAssertEqual(events, [.done(StepsUsage())])
        let (request, body) = try XCTUnwrap(seen.value)
        XCTAssertEqual(request.url?.path, "/ai/steps")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        XCTAssertEqual(json?["image"] as? String, jpeg.base64EncodedString())
    }

    private func collect(_ reply: MockURLProtocol.Reply) async -> ([StepEvent], SessionError?) {
        var events: [StepEvent] = []
        do {
            for try await event in client({ _, _ in reply }).steps(object: "o", parts: parts, instructions: "i") { events.append(event) }
            return (events, nil)
        } catch {
            return (events, error as? SessionError)
        }
    }

    func testStepsErrorEventThrowsAfterEarlierSteps() async {
        let text = """
        event: step
        data: {"index":0,"title":"t","text":"x","focus":[],"avoid":[]}

        event: error
        data: {"code":"ai_invalid_response","message":"AI-მ არასწორი პასუხი დააბრუნა, სცადე თავიდან"}


        """
        let (events, error) = await collect(MockURLProtocol.Reply(chunks: chunks(text, at: [20, 90])))
        XCTAssertEqual(events, [.step(Step(index: 0, title: "t", text: "x"))])
        XCTAssertEqual(error, .server(code: "ai_invalid_response", message: "AI-მ არასწორი პასუხი დააბრუნა, სცადე თავიდან"))
    }

    func testStepsErrorEventTimeoutMapsToTimeout() async {
        let (_, error) = await collect(MockURLProtocol.Reply(chunks: [Data("event: error\ndata: {\"code\":\"ai_timeout\",\"message\":\"…\"}\n\n".utf8)]))
        XCTAssertEqual(error, .timeout)
    }

    func testStepsHTTPErrorBeforeStream() async {
        let (events, error) = await collect(.json(429, #"{"error":{"code":"daily_limit","message":"ლიმიტი"}}"#, headers: ["Retry-After": "60"]))
        XCTAssertEqual(events, [])
        XCTAssertEqual(error, .server(code: "daily_limit", message: "ლიმიტი"))
        let (_, unauthorized) = await collect(.json(401, #"{"error":{"code":"unauthorized","message":"ავტორიზაცია საჭიროა"}}"#))
        XCTAssertEqual(unauthorized, .unauthorized)
    }

    func testStepsStreamCutBeforeDoneIsIncomplete() async {
        let (events, error) = await collect(MockURLProtocol.Reply(chunks: [Data("event: step\ndata: {\"index\":0,\"title\":\"t\",\"text\":\"x\",\"focus\":[],\"avoid\":[]}\n\n".utf8)]))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(error, .server(code: "ai_incomplete", message: ""))
    }

    func testStepsMalformedStepIsBadResponse() async {
        let (_, error) = await collect(MockURLProtocol.Reply(chunks: [Data("event: step\ndata: {\"title\":1}\n\n".utf8)]))
        XCTAssertEqual(error, .server(code: "bad_response", message: ""))
    }

    func testStepsUnauthorizedTokenProviderFailsStream() async {
        struct NoSession: TokenProviding {
            func validToken() async throws -> String { throw SessionError.unauthorized }
        }
        let url = MockURLProtocol.register { _, _ in XCTFail("must not send"); return .json(500, "") }
        let api = KadriClient(config: APIConfig(baseURL: url), auth: NoSession(), session: MockURLProtocol.session())
        do {
            for try await _ in api.steps(object: "o", parts: parts, instructions: "i") {}
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? SessionError, .unauthorized)
        }
    }

    func testCancellingConsumerStopsTheRequest() async throws {
        let stopped = DispatchSemaphore(value: 0)
        let first = Data("event: step\ndata: {\"index\":0,\"title\":\"t\",\"text\":\"x\",\"focus\":[],\"avoid\":[]}\n\n".utf8)
        let api = client { _, _ in
            var reply = MockURLProtocol.Reply(chunks: [first, Data("event: done\ndata: {}\n\n".utf8)]) { i in
                // The second chunk would only come after a long model pause.
                if i == 1 { Thread.sleep(forTimeInterval: 3) }
            }
            reply.onStop = { stopped.signal() }
            return reply
        }
        var count = 0
        for try await _ in api.steps(object: "o", parts: parts, instructions: "i") {
            count += 1
            break
        }
        XCTAssertEqual(count, 1)
        // Leaving the loop terminates the stream, which cancels the URLSession task.
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success, "request must be cancelled when the consumer stops")
    }

    // MARK: health + config

    func testHealth() async throws {
        let api = client(token: nil) { request, _ in
            XCTAssertEqual(request.url?.path, "/health")
            XCTAssertEqual(request.httpMethod, "GET")
            return .json(200, #"{"ok":true,"env":"dev","provider":"astra","version":"dev"}"#)
        }
        let health = try await api.health()
        XCTAssertTrue(health.ok)
        XCTAssertEqual(health.provider, "astra")
    }

    func testConfigURLJoiningAndDefaults() {
        let config = APIConfig(baseURL: URL(string: "http://192.168.1.20:8797")!)
        XCTAssertEqual(config.url("/ai/parts").absoluteString, "http://192.168.1.20:8797/ai/parts")
        XCTAssertGreaterThan(config.aiTimeout, 60, "must outlast the Worker's 60 s AI timeout")
        XCTAssertNil(APIConfig.fromBundle(Bundle(for: APIClientTests.self)))
    }

    func testStreamErrorMapping() {
        XCTAssertEqual(KadriClient.streamError(Data("garbage".utf8)), .server(code: "ai_upstream", message: ""))
        XCTAssertEqual(KadriClient.streamError(Data(#"{"code":"unauthorized","message":"x"}"#.utf8)), .unauthorized)
    }
}

/// A response that starts successfully and then loses the transport; the shared stub fails
/// before headers, so this specifically exercises the non-replay boundary.
private final class ResponseFailureProtocol: URLProtocol, @unchecked Sendable {
    static let calls = Locked(0)
    static let failure = Locked(URLError.networkConnectionLost)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.value += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": request.url?.path == "/ai/steps" ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let text = request.url?.path == "/ai/steps"
            ? "event: step\ndata: {\"index\":0,\"title\":\"t\",\"text\":\"x\",\"focus\":[],\"avoid\":[]}\n\n"
            : "{\"object\":"
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        let code = Self.failure.value
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }
    override func stopLoading() {}
}
