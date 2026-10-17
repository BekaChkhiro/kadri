import CoreText
import UIKit
import XCTest
@testable import Kadri

final class KadriTests: XCTestCase {
    func testCameraUsageDescriptionIsGeorgian() {
        let text = Bundle(for: Self.self).object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        XCTAssertEqual(text, "კადრი კამერას იყენებს ობიექტის დასანახად და ინსტრუქციის საჩვენებლად")
    }
}

final class FontRegistrationTests: XCTestCase {
    func testBundledFontsAreRegistered() {
        for weight in Theme.FontWeight.allCases {
            XCTAssertNotNil(UIFont(name: weight.interName, size: 17), weight.interName)
            XCTAssertNotNil(UIFont(name: weight.georgianName, size: 17), weight.georgianName)
        }
    }

    func testGeorgianGlyphsCascadeToNoto() {
        let font = Theme.ctFont(size: 17, weight: .semibold)
        let text = "ნაბიჯი" as CFString
        let used = CTFontCreateForString(font, text, CFRange(location: 0, length: CFStringGetLength(text)))
        XCTAssertEqual(CTFontCopyPostScriptName(used) as String, "NotoSansGeorgian-SemiBold")
        XCTAssertEqual(CTFontCopyPostScriptName(font) as String, "Inter-SemiBold")
    }
}
