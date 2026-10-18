#if DEBUG
import Foundation
import KadriCore

extension MockKadriAPI {
    static let askResult = AskResult(partLabel: "სიფონის ქანჩი",
        answer: "ეს სიფონის შემაერთებელი ქანჩია. მილსა და შუასადებს ადგილზე ამაგრებს.",
        size: "32 მმ", sizeSource: "typical",
        fitCheck: "შეამოწმე რულეტკით; გასაღები მჭიდროდ უნდა მოერგოს, ძალას ნუ დაატან.",
        suggestStep: "შეამოწმე შუასადები", confidence: .medium)

    func ask(keyframe: Data, question: String, box: [Int]?, partId: String?, parts: [Part],
             context: AskContext?, provider: AIProvider?) async throws -> AskResult {
        try await Task.sleep(for: scanDelay)
        if let failure { throw failure }
        return Self.askResult
    }
}
#endif
