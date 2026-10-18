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
    public let icon: String?
    public let toolItems: [StepTool]?
    public let toolCards: [StepToolCard]?
    public let actions: [StepAction]?
    public let hands: [StepHand]?

    public init(index: Int, title: String, text: String, focus: [String] = [], avoid: [String] = [],
                markers: [StepMarker] = [], arrows: [StepArrow] = [], tools: [String] = [],
                warn: String? = nil, tip: String? = nil, icon: String? = nil, toolItems: [StepTool]? = nil,
                toolCards: [StepToolCard]? = nil, actions: [StepAction]? = nil, hands: [StepHand]? = nil) {
        self.index = index; self.title = title; self.text = text
        self.focus = focus; self.avoid = avoid; self.markers = markers; self.arrows = arrows
        self.tools = tools; self.warn = warn; self.tip = tip
        self.icon = icon; self.toolItems = toolItems
        self.toolCards = toolCards; self.actions = actions; self.hands = hands
    }

    private enum CodingKeys: String, CodingKey {
        case index, title, text, focus, avoid, markers, arrows, tools, warn, tip, icon, toolItems, toolCards, actions, hands
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
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        toolItems = try c.decodeIfPresent([StepTool].self, forKey: .toolItems)
        toolCards = try c.decodeIfPresent([StepToolCard].self, forKey: .toolCards)
        actions = try c.decodeIfPresent([StepAction].self, forKey: .actions)
        hands = try c.decodeIfPresent([StepHand].self, forKey: .hands)?.filter { $0.isSupported }
    }
}

/// A catalog tool the step needs (capability "tools_v2"); `id` is a `ToolCatalog` id.
public struct StepToolCard: Hashable, Codable, Sendable {
    public let id: String
    public let size: String?
    public let sizeSource: String
    public let fitCheck: String?
    public let alternatives: [String]
    public let why: String
    public let notThis: NotThis?

    /// A tool that looks right but is wrong for this step.
    public struct NotThis: Hashable, Codable, Sendable {
        public let id: String
        public let reason: String
        public init(id: String, reason: String) {
            self.id = id; self.reason = reason
        }
    }

    public init(id: String, size: String? = nil, why: String, notThis: NotThis? = nil,
                sizeSource: String = "typical", fitCheck: String? = nil, alternatives: [String] = []) {
        self.id = id; self.size = size; self.why = why; self.notThis = notThis
        self.sizeSource = sizeSource; self.fitCheck = fitCheck; self.alternatives = alternatives
    }

    private enum CodingKeys: String, CodingKey {
        case id, size, why, notThis, sizeSource, fitCheck, alternatives
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        size = try c.decodeIfPresent(String.self, forKey: .size)
        why = try c.decode(String.self, forKey: .why)
        notThis = try c.decodeIfPresent(NotThis.self, forKey: .notThis)
        sizeSource = try c.decodeIfPresent(String.self, forKey: .sizeSource) ?? "typical"
        fitCheck = try c.decodeIfPresent(String.self, forKey: .fitCheck)
        alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives) ?? []
    }
}

/// A motion to show on a part (capability "tools_v2"). `amount` applies to turns, `order` to `tighten_order`.
public struct StepAction: Hashable, Codable, Sendable {
    public let part: String
    public let kind: String
    public let amount: String?
    public let order: [String]?

    public init(part: String, kind: String, amount: String? = nil, order: [String]? = nil) {
        self.part = part; self.kind = kind; self.amount = amount; self.order = order
    }
}

public struct StepTool: Hashable, Codable, Sendable {
    public let label: String
    public let icon: String?

    public init(label: String, icon: String? = nil) {
        self.label = label
        self.icon = icon
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

/// Hand hints from hands_v1. Unknown grip/hand values are ignored by Step decoding,
/// rather than guessing a potentially misleading gesture.
public struct StepHand: Hashable, Codable, Sendable {
    public let part: String
    public let grip: String
    public let hand: String
    public let byHandOnly: Bool

    public var isSupported: Bool {
        ["hold", "turn", "push", "pull", "support"].contains(grip) &&
        ["left", "right", "both"].contains(hand)
    }

    public init(part: String, grip: String, hand: String, byHandOnly: Bool) {
        self.part = part; self.grip = grip; self.hand = hand; self.byHandOnly = byHandOnly
    }
}
