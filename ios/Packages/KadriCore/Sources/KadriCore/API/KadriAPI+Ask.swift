import Foundation

extension KadriClient {
    public func ask(keyframe: Data, question: String, box: [Int]?, partId: String?, parts: [Part],
                    context: AskContext?, provider: AIProvider?) async throws -> AskResult {
        var form = MultipartForm()
        form.addFile(name: "image", filename: "keyframe.jpg", contentType: "image/jpeg", data: keyframe)
        form.addField(name: "question", value: question.trimmingCharacters(in: .whitespacesAndNewlines))
        func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
        if let box { form.addField(name: "box", value: try json(box)) }
        if let partId { form.addField(name: "partId", value: partId) }
        form.addField(name: "parts", value: try json(parts))
        if let context { form.addField(name: "context", value: try json(context)) }
        if let provider { form.addField(name: "provider", value: provider.rawValue) }
        var request = try await authorizedRequest("/ai/ask")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.body()
        let data = try await session.kadriData(for: request)
        return try decodeResponse(AskResult.self, from: data)
    }
}
