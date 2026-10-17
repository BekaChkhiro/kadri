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

/// One instruction step. `focus` and `avoid` hold part ids.
public struct Step: Hashable, Codable, Sendable {
    public let index: Int
    public let title: String
    public let text: String
    public let focus: [String]
    public let avoid: [String]

    public init(index: Int, title: String, text: String, focus: [String] = [], avoid: [String] = []) {
        self.index = index
        self.title = title
        self.text = text
        self.focus = focus
        self.avoid = avoid
    }
}
