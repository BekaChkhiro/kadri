import Foundation

/// Supplies the Bearer session token for Worker requests. `AuthStore` is the real one.
public protocol TokenProviding: Sendable {
    func validToken() async throws -> String
}

/// `GET /health`.
public struct HealthInfo: Hashable, Decodable, Sendable {
    public let ok: Bool
    public let env: String?
    public let provider: String?
    public let version: String?
}

/// `KadriAPI` over URLSession against the Worker.
///
/// Errors: non-2xx answers become `SessionError(status:body:)`, transport failures `SessionError(_:)`,
/// and an SSE `error` event the matching `SessionError` (`.server`, `.timeout`, `.unauthorized`).
public struct KadriClient: KadriAPI {
    public let config: APIConfig
    private let auth: (any TokenProviding)?
    private let session: URLSession

    /// `auth` nil sends no Authorization header (the AI routes then answer 401 once auth is mounted).
    /// `session` defaults to one configured from `config`; tests pass one with a mock URLProtocol.
    public init(config: APIConfig, auth: (any TokenProviding)?, session: URLSession? = nil) {
        self.config = config
        self.auth = auth
        self.session = session ?? .kadri(config)
    }

    public func health() async throws -> HealthInfo {
        var request = URLRequest(url: config.url("/health"), timeoutInterval: config.requestTimeout)
        request.httpMethod = "GET"
        let data = try await session.kadriData(for: request)
        return try decodeResponse(HealthInfo.self, from: data)
    }

    public func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        try await parts(keyframe: keyframe, instructions: instructions, context: context, provider: nil)
    }

    public func parts(keyframe: Data, instructions: String, context: SessionContext?, provider: AIProvider?) async throws -> PartsResult {
        var form = MultipartForm()
        form.addFile(name: "image", filename: "keyframe.jpg", contentType: "image/jpeg", data: keyframe)
        form.addField(name: "instructions", value: instructions)
        if let provider { form.addField(name: "provider", value: provider.rawValue) }
        if let context {
            form.addField(name: "context", value: String(decoding: try JSONEncoder().encode(context), as: UTF8.self))
        }

        var request = try await authorizedRequest("/ai/parts")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.body()
        let data = try await session.kadriData(for: request)
        let body = try decodeResponse(PartsBody.self, from: data)
        return PartsResult(object: body.object, parts: body.parts, latencyMs: body.latencyMs.map { Int($0.rounded()) })
    }

    public func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        steps(object: object, parts: parts, instructions: instructions, image: nil, context: context)
    }

    public func steps(object: String, parts: [Part], instructions: String, context: SessionContext?, provider: AIProvider?) -> AsyncThrowingStream<StepEvent, Error> {
        steps(object: object, parts: parts, instructions: instructions, image: nil, context: context, provider: provider)
    }

    /// `POST /ai/steps`; `image` (JPEG) is optional and lets the model look at the frame again.
    public func steps(object: String, parts: [Part], instructions: String, image: Data?,
                      context: SessionContext? = nil, provider: AIProvider? = nil) -> AsyncThrowingStream<StepEvent, Error> {
        let body = StepsRequest(object: object, parts: parts, instructions: instructions,
                                image: image?.base64EncodedString(), context: context, provider: provider)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamSteps(body, into: continuation)
                    continuation.finish()
                } catch {
                    #if DEBUG
                    print("[Kadri] /ai/steps failed: \(String(reflecting: error))")
                    #endif
                    continuation.finish(throwing: SessionError(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamSteps(_ body: StepsRequest, into continuation: AsyncThrowingStream<StepEvent, Error>.Continuation) async throws {
        var request = try await authorizedRequest("/ai/steps")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw SessionError(status: status, body: data)
        }

        var parser = SSEParser()
        for try await byte in bytes {
            if let message = parser.push(byte), try handle(message, continuation) { return }
        }
        try Task.checkCancellation()
        if let message = parser.finish(), try handle(message, continuation) { return }
        // The Worker always ends with `done` or `error`; anything else is a cut-off stream.
        throw SessionError.server(code: "ai_incomplete", message: "")
    }

    /// Yields one SSE message; returns true once the stream is complete.
    private func handle(_ message: SSEMessage, _ continuation: AsyncThrowingStream<StepEvent, Error>.Continuation) throws -> Bool {
        let data = Data(message.data.utf8)
        switch message.event {
        case "step":
            continuation.yield(.step(try decodeResponse(Step.self, from: data)))
            return false
        case "done":
            let done = try? JSONDecoder().decode(DoneBody.self, from: data)
            continuation.yield(.done(done?.stepsUsage, continuation: done?.continuation ?? .complete))
            return true
        case "error":
            throw Self.streamError(data)
        default:
            return false
        }
    }

    /// Maps an SSE `error` payload `{code, message}` the same way as an HTTP error body.
    static func streamError(_ data: Data) -> SessionError {
        guard (try? JSONDecoder().decode(SessionError.ServerBody.Detail.self, from: data)) != nil else {
            return .server(code: "ai_upstream", message: "")
        }
        return SessionError(status: 200, body: Data("{\"error\":".utf8) + data + Data("}".utf8))
    }

    private func authorizedRequest(_ path: String) async throws -> URLRequest {
        var request = URLRequest(url: config.url(path), timeoutInterval: config.aiTimeout)
        request.httpMethod = "POST"
        if let auth {
            request.setValue("Bearer \(try await auth.validToken())", forHTTPHeaderField: "Authorization")
        }
        return request
    }
}

// MARK: - Wire types

private struct PartsBody: Decodable {
    let object: String
    let parts: [Part]
    let latencyMs: Double?
}

private struct StepsRequest: Encodable {
    // nil is omitted to preserve the default Astra request.
    let capabilities = ["needs_answer", "needs_measurement", "summary"]
    let object: String
    let parts: [Part]
    let instructions: String
    let image: String?
    /// Omitted when nil (synthesized `encodeIfPresent`).
    let context: SessionContext?
    let provider: AIProvider?
}

/// `done` payload: `{unknownParts, usage: {input_tokens, output_tokens, output_tokens_details}, costUsd, latencyMs, firstStepMs, model, continuation}`.
private struct DoneBody: Decodable {
    struct Usage: Decodable {
        struct OutputDetails: Decodable {
            let reasoning_tokens: Int?
        }
        let input_tokens: Int?
        let output_tokens: Int?
        let output_tokens_details: OutputDetails?
    }
    let usage: Usage?
    let costUsd: Double?
    let latencyMs: Double?
    /// Missing on Workers older than multi-photo sessions.
    let continuation: StepsContinuation?

    var stepsUsage: StepsUsage {
        StepsUsage(
            inputTokens: usage?.input_tokens,
            outputTokens: usage?.output_tokens,
            reasoningTokens: usage?.output_tokens_details?.reasoning_tokens,
            costUsd: costUsd,
            latencyMs: latencyMs.map { Int($0.rounded()) }
        )
    }
}

struct MultipartForm {
    let boundary = "kadri-\(UUID().uuidString)"
    private var data = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(name: String, value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        data.append(Data(value.utf8))
        data.append(Data("\r\n".utf8))
    }

    mutating func addFile(name: String, filename: String, contentType: String, data file: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        data.append(file)
        data.append(Data("\r\n".utf8))
    }

    func body() -> Data {
        data + Data("--\(boundary)--\r\n".utf8)
    }
}

// MARK: - Transport

func decodeResponse<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        throw SessionError.server(code: "bad_response", message: "")
    }
}

extension URLSession {
    static func kadri(_ config: APIConfig) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = config.aiTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    /// Body of a 2xx response; throws `SessionError` for HTTP errors and transport failures.
    func kadriData(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.data(for: request)
        } catch {
            #if DEBUG
            print("[Kadri] \(request.url?.path ?? "?") transport failed: \(String(reflecting: error))")
            #endif
            throw SessionError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw SessionError(status: status, body: data) }
        return data
    }
}
