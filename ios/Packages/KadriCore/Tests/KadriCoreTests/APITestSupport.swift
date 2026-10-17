import Foundation
@testable import KadriCore

/// URLProtocol that answers from a handler registered per host, so every test gets its own fake Worker.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    /// What one request gets back. Chunks are sent one by one; `beforeChunk` runs on the loading
    /// thread before each chunk is sent (to hold one back until the client has seen the previous).
    struct Reply: Sendable {
        var status: Int = 200
        var headers: [String: String] = [:]
        var chunks: [Data]
        var beforeChunk: (@Sendable (Int) -> Void)?
        /// Fails the request with this error instead of answering.
        var failure: URLError?
        /// Called when URLSession stops the load (finished or cancelled).
        var onStop: (@Sendable () -> Void)?

        static func json(_ status: Int, _ body: String, headers: [String: String] = [:]) -> Reply {
            Reply(status: status, headers: headers.merging(["Content-Type": "application/json"]) { a, _ in a }, chunks: [Data(body.utf8)])
        }
    }

    typealias Handler = @Sendable (URLRequest, Data) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    /// Registers a fake Worker and returns its base URL.
    static func register(_ handler: @escaping Handler) -> URL {
        let host = "w\(UUID().uuidString.prefix(8).lowercased()).test"
        lock.withLock { handlers[host] = handler }
        return URL(string: "https://\(host)")!
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private var stopped = false
    private var onStop: (@Sendable () -> Void)?
    private let stoppedLock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let host = request.url?.host, let handler = Self.lock.withLock({ Self.handlers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = handler(request, Self.body(of: request))
        stoppedLock.withLock { onStop = reply.onStop }
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let thread = Thread { [self] in
            for (i, chunk) in reply.chunks.enumerated() {
                reply.beforeChunk?(i)
                if stoppedLock.withLock({ stopped }) { return }
                client?.urlProtocol(self, didLoad: chunk)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
        thread.start()
    }

    override func stopLoading() {
        let onStop = stoppedLock.withLock { stopped = true; return self.onStop }
        onStop?()
    }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// Splits `text` into chunks at the given byte offsets.
func chunks(_ text: String, at offsets: [Int]) -> [Data] {
    let bytes = Array(text.utf8)
    var result: [Data] = []
    var start = 0
    for offset in offsets.sorted() where offset > start && offset < bytes.count {
        result.append(Data(bytes[start..<offset]))
        start = offset
    }
    result.append(Data(bytes[start...]))
    return result
}

struct StaticToken: TokenProviding {
    let token: String
    func validToken() async throws -> String { token }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { _value = value }
    var value: Value {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
