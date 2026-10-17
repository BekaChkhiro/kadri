import XCTest
@testable import Kadri

final class KadriTests: XCTestCase {
    func testCameraUsageDescriptionIsGeorgian() {
        let text = Bundle(for: Self.self).object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String
        XCTAssertEqual(text, "კადრი კამერას იყენებს ობიექტის დასანახად და ინსტრუქციის საჩვენებლად")
    }
}
