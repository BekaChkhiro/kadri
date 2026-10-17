import CoreText
import SwiftUI

/// Design tokens from Camera/theme.json. ThemeTests keeps the two in sync.
public enum Theme {
    public enum Hex {
        public static let brand: [Int: String] = [
            50: "#eef4ff", 100: "#dae6ff", 200: "#bcd2ff", 300: "#8eb4ff", 400: "#5b8cff",
            500: "#2f6bff", 600: "#1f52f0", 700: "#1a41d6", 800: "#1c37ad", 900: "#1d3388",
            950: "#162153",
        ]
        public static let ink: [Int: String] = [
            50: "#f8fafc", 100: "#f1f5f9", 200: "#e2e8f0", 300: "#cbd5e1", 400: "#94a3b8",
            500: "#64748b", 600: "#475569", 700: "#334155", 800: "#1e293b", 900: "#0f172a",
            950: "#020617",
        ]
        public static let surface = "#f7f7f5"
    }

    public enum Colors {
        public static let shades = [50, 100, 200, 300, 400, 500, 600, 700, 800, 900, 950]
        public static let brand: [Int: Color] = Hex.brand.mapValues { Color(hex: $0) }
        public static let ink: [Int: Color] = Hex.ink.mapValues { Color(hex: $0) }
        public static let surface = Color(hex: Hex.surface)
    }

    /// theme.json radii in points (rem × 16). `pill` is a full capsule.
    public enum Radius {
        public static let btn: CGFloat = 14
        public static let card: CGFloat = 24
        public static let field: CGFloat = 12
        public static let pill: CGFloat = .infinity
    }

    /// The dominant layer of each CSS shadow; SwiftUI radius is the CSS blur / 2.
    public enum Shadow {
        public static let card = ShadowStyle(color: Color(hex: Hex.ink[900]!).opacity(0.12), radius: 12, y: 8)
        public static let pop = ShadowStyle(color: Color(hex: Hex.ink[900]!).opacity(0.28), radius: 20, y: 16)
    }

    public enum FontWeight: Sendable, CaseIterable {
        case regular, medium, semibold, bold

        var suffix: String {
            switch self {
            case .regular: "Regular"
            case .medium: "Medium"
            case .semibold: "SemiBold"
            case .bold: "Bold"
            }
        }

        public var interName: String { "Inter-\(suffix)" }
        public var georgianName: String { "NotoSansGeorgian-\(suffix)" }
    }
}

public struct ShadowStyle: Sendable {
    public let color: Color
    public let radius: CGFloat
    public let x: CGFloat
    public let y: CGFloat

    public init(color: Color, radius: CGFloat, x: CGFloat = 0, y: CGFloat) {
        self.color = color
        self.radius = radius
        self.x = x
        self.y = y
    }
}

extension Font {
    /// Inter for Latin; glyphs Inter lacks (Georgian) cascade to Noto Sans Georgian of the same weight.
    public static func kadri(_ size: CGFloat, weight: Theme.FontWeight = .regular) -> Font {
        Font(Theme.ctFont(size: size, weight: weight))
    }
}

extension Theme {
    public static func ctFont(size: CGFloat, weight: FontWeight) -> CTFont {
        let fallback = CTFontDescriptorCreateWithNameAndSize(weight.georgianName as CFString, size)
        let attributes: [CFString: Any] = [
            kCTFontNameAttribute: weight.interName,
            kCTFontCascadeListAttribute: [fallback],
        ]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }
}

extension View {
    public func shadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}

extension Color {
    /// `#rrggbb` or `rrggbb` in sRGB. Invalid input gives black.
    public init(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = digits.count == 6 ? UInt32(digits, radix: 16) ?? 0 : 0
        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }
}
