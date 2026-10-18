import Foundation

extension KadriClient {
    public func problem(_ body: ProblemRequest) async throws -> ProblemResult {
        var request = try await authorizedRequest("/ai/problem")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data = try await session.kadriData(for: request)
        try Task.checkCancellation()
        let result = try decodeResponse(ProblemResult.self, from: data)
        try result.validate(for: body)
        return result
    }
}
