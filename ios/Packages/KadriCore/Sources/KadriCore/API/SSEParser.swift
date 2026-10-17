import Foundation

/// One Server-Sent Events message. `event` is nil when the server sent no `event:` field.
public struct SSEMessage: Hashable, Sendable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental SSE parser, fed bytes as they arrive. Splits lines on LF, CRLF or CR (also when a CRLF
/// is split across chunks), joins multi-line `data:`, dispatches on an empty line, and ignores
/// comments, `id:`, `retry:` and unknown fields. Mirrors the Worker's `readSse`.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var event: String?
    private var data: [String] = []

    public init() {}

    /// Feeds one byte; returns a message when this byte completed one.
    public mutating func push(_ byte: UInt8) -> SSEMessage? {
        switch byte {
        case 0x0A where lastWasCR:
            lastWasCR = false
            return nil
        case 0x0A, 0x0D:
            lastWasCR = byte == 0x0D
            let finished = line
            line.removeAll(keepingCapacity: true)
            return processLine(finished)
        default:
            lastWasCR = false
            line.append(byte)
            return nil
        }
    }

    /// Feeds a chunk; returns the messages it completed, in order.
    public mutating func push<Bytes: Sequence>(_ bytes: Bytes) -> [SSEMessage] where Bytes.Element == UInt8 {
        bytes.compactMap { push($0) }
    }

    /// End of stream: a trailing line without a newline and an undispatched message are flushed.
    public mutating func finish() -> SSEMessage? {
        if !line.isEmpty {
            let finished = line
            line.removeAll()
            _ = processLine(finished)
        }
        lastWasCR = false
        return processLine([])
    }

    private mutating func processLine(_ bytes: [UInt8]) -> SSEMessage? {
        if bytes.isEmpty {
            defer {
                event = nil
                data = []
            }
            return data.isEmpty ? nil : SSEMessage(event: event, data: data.joined(separator: "\n"))
        }
        if bytes.first == UInt8(ascii: ":") { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }
}
