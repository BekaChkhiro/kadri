import XCTest
import SwiftUI
@testable import Kadri

@MainActor
final class PhotoArrowDemoTests: XCTestCase {
    func testEveryDirectionOnPhotoAtDifferentScales() async throws {
        let directory = URL(fileURLWithPath: "/tmp/kadri-arrow-shots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scenario in 0...2 { XCTAssertNotNil(PhotoArrowDemoScene.image(scenario)) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        for (index, kind) in PhotoArrowKind.allCases.enumerated() {
            let view = PhotoArrowDemoScene(scenario: index % 3, kind: kind,
                                           zoom: index.isMultiple(of: 2) ? 0.65 : 1.4, fixedPhase: 0.5)
                .frame(width: 360, height: 390)
            let host = UIHostingController(rootView: view)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 360, height: 390)
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
            let data = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(data.count, 1000)
            try data.write(to: directory.appendingPathComponent("\(kind.rawValue).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = kind.rawValue
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
        previous?.makeKeyAndVisible()
    }
}
