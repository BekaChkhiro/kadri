import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class PhotoToolSymbolTests: XCTestCase {
    func testEveryCatalogToolHasItsNewAsset() throws {
        XCTAssertEqual(ToolCatalog.ids.count, 32)
        for id in ToolCatalog.ids {
            let asset = try XCTUnwrap(PhotoToolSymbol.assetName(for: id))
            XCTAssertNotEqual(asset, ToolCatalog.assetName(id), "Must not display the retired 3D asset")
            XCTAssertNotNil(UIImage(named: asset), "Missing icon for \(id)")
        }
        XCTAssertNil(PhotoToolSymbol.assetName(for: "bolt.fill"))
        XCTAssertNil(PhotoToolSymbol.assetName(for: "not-a-tool"))
    }

    func testDriveProfilesAreSpecificAndAvailable() {
        XCTAssertEqual(PhotoToolSymbol.profile(for: "ph1"), .phillips)
        XCTAssertEqual(PhotoToolSymbol.profile(for: "ph2"), .phillips)
        XCTAssertEqual(PhotoToolSymbol.profile(for: "flat_small"), .slotted)
        XCTAssertEqual(PhotoToolSymbol.profile(for: "flat_large"), .slotted)
        XCTAssertEqual(PhotoToolSymbol.profile(for: "torx_t10"), .torx)
        XCTAssertEqual(PhotoToolSymbol.profile(for: "torx_t20"), .torx)
        XCTAssertEqual(PhotoToolSymbol.profile(for: "hex_key"), .hex)
        XCTAssertNil(PhotoToolSymbol.profile(for: "pliers"))
        XCTAssertNil(PhotoToolSymbol.profile(for: "ph-unknown"))
        for profile in PhotoToolSymbol.Profile.allCases {
            XCTAssertNotNil(UIImage(named: profile.assetName), profile.rawValue)
        }
    }

    func testHardwareUsesActualMechanicalAssets() throws {
        for hardware in PhotoToolSymbol.Hardware.allCases {
            XCTAssertTrue(hardware.assetName.hasPrefix("hardware-"))
            XCTAssertNotNil(UIImage(named: hardware.assetName))
        }
        let nut = try XCTUnwrap(UIImage(named: PhotoToolSymbol.Hardware.nut.assetName)?.pngData())
        let screw = try XCTUnwrap(UIImage(named: PhotoToolSymbol.Hardware.screw.assetName)?.pngData())
        XCTAssertNotEqual(nut, screw)
        if let lightning = UIImage(systemName: "bolt.fill")?.pngData() {
            XCTAssertNotEqual(screw, lightning)
            XCTAssertNotEqual(nut, lightning)
        }
    }

    func testGenericLabelsMatchTheVerifiedSourceCatalog() throws {
        struct Catalog: Decodable {
            struct Asset: Decodable {
                let toolId: String?
                let coverage: String?
            }
            let assets: [Asset]
        }
        let url = try XCTUnwrap(Bundle.main.url(forResource: "ToolSymbols-Sources", withExtension: "json"))
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        let placeholders = Set(catalog.assets.filter { $0.coverage == "placeholder" }.compactMap(\.toolId))
        XCTAssertEqual(placeholders, PhotoToolSymbol.genericToolIDs,
                       "Gallery labels must distinguish actual tool silhouettes from placeholders")
        XCTAssertEqual(Set(catalog.assets.compactMap(\.toolId)), Set(ToolCatalog.ids))
    }

    func testProductionCardsAndProfilesRender() async throws {
        let directory = URL(fileURLWithPath: "/tmp/kadri-tool-symbol-shots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let cases: [(String, AnyView, CGFloat)] = [
            ("profiles", AnyView(PhotoToolProfileGallery().padding(16)), 145),
            ("cards", AnyView(PhotoToolCardSamples().padding(16)), 1150),
            ("gallery", AnyView(PhotoToolIconDemoView()), 850)
        ]
        for (name, content, height) in cases {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
            let host = UIHostingController(rootView: content.background(Theme.Colors.surface))
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let png = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(png.count, 1000)
            try png.write(to: directory.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = "tool-symbol-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
        }
        previous?.makeKeyAndVisible()
    }
}
