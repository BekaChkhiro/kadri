import Foundation

/// One session on the backend; the id comes from the server.
public struct SessionID: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// A part the AI found in the frame. `box` is XYXY on a 0–1000 grid.
public struct Part: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let box: [Int]

    public init(id: String, name: String, box: [Int]) {
        self.id = id
        self.name = name
        self.box = box
    }

    /// True when `box` has four coordinates inside 0…1000 with x1 < x2 and y1 < y2.
    public var hasValidBox: Bool {
        guard box.count == 4, box.allSatisfy({ (0...1000).contains($0) }) else { return false }
        return box[0] < box[2] && box[1] < box[3]
    }
}

/// One instruction step. Missing presentation fields remain compatible with older sessions.
public struct Step: Hashable, Codable, Sendable {
    public let index: Int
    public let title: String
    public let text: String
    public let focus: [String]
    public let avoid: [String]
    public let markers: [StepMarker]
    public let arrows: [StepArrow]
    public let tools: [String]
    public let warn: String?
    public let tip: String?

    public init(index: Int, title: String, text: String, focus: [String] = [], avoid: [String] = [],
                markers: [StepMarker] = [], arrows: [StepArrow] = [], tools: [String] = [],
                warn: String? = nil, tip: String? = nil) {
        self.index = index; self.title = title; self.text = text
        self.focus = focus; self.avoid = avoid; self.markers = markers; self.arrows = arrows
        self.tools = tools; self.warn = warn; self.tip = tip
    }

    private enum CodingKeys: String, CodingKey {
        case index, title, text, focus, avoid, markers, arrows, tools, warn, tip
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        index = try c.decode(Int.self, forKey: .index)
        title = try c.decode(String.self, forKey: .title)
        text = try c.decode(String.self, forKey: .text)
        focus = try c.decodeIfPresent([String].self, forKey: .focus) ?? []
        avoid = try c.decodeIfPresent([String].self, forKey: .avoid) ?? []
        markers = try c.decodeIfPresent([StepMarker].self, forKey: .markers) ?? []
        arrows = try c.decodeIfPresent([StepArrow].self, forKey: .arrows) ?? []
        tools = try c.decodeIfPresent([String].self, forKey: .tools) ?? []
        warn = try c.decodeIfPresent(String.self, forKey: .warn)
        tip = try c.decodeIfPresent(String.self, forKey: .tip)
    }
}

public struct StepMarker: Hashable, Codable, Sendable {
    public let part: String
    public let label: String
    public let tone: String
    public init(part: String, label: String, tone: String = "brand") {
        self.part = part; self.label = label; self.tone = tone
    }
}

public struct StepArrow: Hashable, Codable, Sendable {
    public let part: String
    public let type: String
    public let dir: String
    public init(part: String, type: String, dir: String) {
        self.part = part; self.type = type; self.dir = dir
    }
}
