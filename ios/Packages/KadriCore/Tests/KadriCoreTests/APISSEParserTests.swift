import XCTest
@testable import KadriCore

final class APISSEParserTests: XCTestCase {
    private func parse(_ chunks: [String]) -> [SSEMessage] {
        var parser = SSEParser()
        var out = chunks.flatMap { parser.push(Array($0.utf8)) }
        if let last = parser.finish() { out.append(last) }
        return out
    }

    func testEventAndData() {
        XCTAssertEqual(parse(["event: step\ndata: {\"a\":1}\n\n"]), [SSEMessage(event: "step", data: "{\"a\":1}")])
    }

    func testMultiLineDataIsJoinedWithNewlines() {
        XCTAssertEqual(parse(["data: one\ndata: two\ndata:three\n\n"]), [SSEMessage(event: nil, data: "one\ntwo\nthree")])
    }

    func testCommentsRetryAndIdAreIgnored() {
        let text = ": keep-alive\nretry: 3000\nid: 7\nevent: done\nfoo: bar\ndata: {}\n\n"
        XCTAssertEqual(parse([text]), [SSEMessage(event: "done", data: "{}")])
    }

    func testCRLFAndCRLineEndings() {
        XCTAssertEqual(
            parse(["event: a\r\ndata: 1\r\n\r\nevent: b\rdata: 2\r\r"]),
            [SSEMessage(event: "a", data: "1"), SSEMessage(event: "b", data: "2")]
        )
    }

    func testCRLFSplitAcrossChunks() {
        XCTAssertEqual(parse(["event: a\r", "\ndata: 1\r", "\n\r", "\n"]), [SSEMessage(event: "a", data: "1")])
    }

    func testByteAtATimeWithMultibyteGeorgian() {
        let text = "event: step\ndata: {\"title\":\"სიფონის მოხსნა\"}\n\n"
        var parser = SSEParser()
        let out = Array(text.utf8).compactMap { parser.push($0) }
        XCTAssertEqual(out, [SSEMessage(event: "step", data: "{\"title\":\"სიფონის მოხსნა\"}")])
    }

    func testEventWithoutDataIsNotDispatchedAndResets() {
        XCTAssertEqual(parse(["event: ping\n\ndata: x\n\n"]), [SSEMessage(event: nil, data: "x")])
    }

    func testFinishFlushesUnterminatedMessage() {
        XCTAssertEqual(parse(["event: done\ndata: {}"]), [SSEMessage(event: "done", data: "{}")])
    }

    func testValueWithoutLeadingSpaceAndColonsInValue() {
        XCTAssertEqual(parse(["event:step\ndata:  a:b\n\n"]), [SSEMessage(event: "step", data: " a:b")])
    }
}
