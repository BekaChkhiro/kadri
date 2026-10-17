import SwiftUI
import XCTest
@testable import KadriCore

final class ThemeTests: XCTestCase {
    private struct ThemeFile: Decodable {
        struct Colors: Decodable {
            let brand: [String: String]
            let ink: [String: String]
        }
        let colors: Colors
        let radius: [String: String]
        let shadow: [String: String]
        let surface: String
    }

    /// <repo>/ios/Packages/KadriCore/Tests/KadriCoreTests/ThemeTests.swift → <repo>/Camera/theme.json
    private func loadThemeFile() throws -> ThemeFile {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("Camera/theme.json"))
        return try JSONDecoder().decode(ThemeFile.self, from: data)
    }

    private func components(_ hex: String) -> [Float] {
        let v = UInt32(hex.dropFirst(), radix: 16)!
        return [Float((v >> 16) & 0xFF) / 255, Float((v >> 8) & 0xFF) / 255, Float(v & 0xFF) / 255]
    }

    private func assertColor(_ color: Color?, matches hex: String, _ label: String) {
        guard let color else { return XCTFail("\(label) missing") }
        let r = color.resolve(in: EnvironmentValues())
        let expected = components(hex)
        for (got, want) in zip([r.red, r.green, r.blue], expected) {
            XCTAssertEqual(got, want, accuracy: 0.002, "\(label) \(hex)")
        }
    }

    func testColorsMatchThemeJSON() throws {
        let file = try loadThemeFile()
        XCTAssertEqual(file.colors.brand.count, 11)
        XCTAssertEqual(file.colors.ink.count, 11)
        for (key, hex) in file.colors.brand {
            let shade = try XCTUnwrap(Int(key))
            XCTAssertEqual(Theme.Hex.brand[shade], hex, "brand \(shade)")
            assertColor(Theme.Colors.brand[shade], matches: hex, "brand \(shade)")
        }
        for (key, hex) in file.colors.ink {
            let shade = try XCTUnwrap(Int(key))
            XCTAssertEqual(Theme.Hex.ink[shade], hex, "ink \(shade)")
            assertColor(Theme.Colors.ink[shade], matches: hex, "ink \(shade)")
        }
        XCTAssertEqual(Set(Theme.Hex.brand.keys), Set(file.colors.brand.keys.compactMap(Int.init)))
        XCTAssertEqual(Set(Theme.Hex.ink.keys), Set(file.colors.ink.keys.compactMap(Int.init)))
        XCTAssertEqual(Theme.Hex.surface, file.surface)
        assertColor(Theme.Colors.surface, matches: file.surface, "surface")
    }

    func testRadiiAreRemTimesSixteen() throws {
        let file = try loadThemeFile()
        func points(_ css: String?) throws -> CGFloat {
            let css = try XCTUnwrap(css)
            if css.hasSuffix("rem") { return CGFloat(try XCTUnwrap(Double(css.dropLast(3)))) * 16 }
            if css.hasSuffix("px") { return CGFloat(try XCTUnwrap(Double(css.dropLast(2)))) }
            throw XCTSkip("unknown unit \(css)")
        }
        XCTAssertEqual(Theme.Radius.btn, try points(file.radius["btn"]))
        XCTAssertEqual(Theme.Radius.card, try points(file.radius["card"]))
        XCTAssertEqual(Theme.Radius.field, try points(file.radius["field"]))
        XCTAssertGreaterThanOrEqual(try points(file.radius["pill"]), 9999)
        XCTAssertTrue(Theme.Radius.pill.isInfinite)
    }

    /// Last CSS layer "0 Ypx Bpx [S] rgb(… / A)" → radius B/2, y Y.
    func testShadowsFollowLastCSSLayer() throws {
        let file = try loadThemeFile()
        for (name, style) in [("card", Theme.Shadow.card), ("pop", Theme.Shadow.pop)] {
            let css = try XCTUnwrap(file.shadow[name])
            let layer = css.components(separatedBy: "), ").last!
            let numbers = layer.split(separator: " ").prefix(3).map { Double($0.replacingOccurrences(of: "px", with: ""))! }
            XCTAssertEqual(Double(style.y), numbers[1], name)
            XCTAssertEqual(Double(style.radius), numbers[2] / 2, name)
            let alpha = Double(layer.split(separator: "/").last!.trimmingCharacters(in: CharacterSet(charactersIn: " )")))!
            let resolved = style.color.resolve(in: EnvironmentValues())
            XCTAssertEqual(Double(resolved.opacity), alpha, accuracy: 0.001, name)
        }
    }

    func testFontNamesAndHexParsing() {
        XCTAssertEqual(Theme.FontWeight.semibold.interName, "Inter-SemiBold")
        XCTAssertEqual(Theme.FontWeight.bold.georgianName, "NotoSansGeorgian-Bold")
        let font = Theme.ctFont(size: 17, weight: .medium)
        XCTAssertEqual(CTFontGetSize(font), 17)
        assertColor(Color(hex: "2f6bff"), matches: "#2f6bff", "hex without #")
    }
}
