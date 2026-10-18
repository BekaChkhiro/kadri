import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class PhotoAskTests: XCTestCase {
    private var photo: UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 400)).image { context in
            UIColor.lightGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }
    }
    func testHitTestUsesFocusedPhotoTransform() throws {
        let parts = MockKadriAPI.result.parts
        let part = try XCTUnwrap(parts.first)
        let transform = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -60, ty: 20)
        let rect = PhotoAskGeometry.rect(part.box, imageSize: photo.size, transform: transform)
        let selected = try XCTUnwrap(PhotoAskGeometry.select(point: CGPoint(x: rect.midX, y: rect.midY), imageSize: photo.size, transform: transform, parts: [part]))
        XCTAssertEqual(selected.partId, part.id)
        XCTAssertEqual(selected.box, part.box)
        XCTAssertNil(PhotoAskGeometry.select(point: CGPoint(x: -1000, y: -1000), imageSize: photo.size, transform: transform, parts: parts))
        let fallback = try XCTUnwrap(PhotoAskGeometry.select(point: .zero, imageSize: photo.size, transform: .identity, parts: []))
        XCTAssertEqual(fallback.box, [0, 0, 200, 200])
    }
    func testMaskBoundsAreNormalizedAndEmptyMaskFails() {
        func mask(_ pixels: [UInt8]) -> Mask { Mask(width: 4, height: 2, pixels: pixels, score: 1, scores: [1], selected: 0, decodeMs: 0, postMs: 0) }
        XCTAssertEqual(PhotoAskGeometry.bounds(mask([0, 255, 255, 0, 0, 0, 0, 0])), [250, 0, 750, 500])
        XCTAssertNil(PhotoAskGeometry.bounds(mask(Array(repeating: 0, count: 8))))
        XCTAssertNil(PhotoAskGeometry.bounds(mask([])))
    }
    private func selectedSession(api: any KadriAPI) throws -> PhotoAskSession {
        let session = PhotoAskSession(api: api)
        let part = try XCTUnwrap(MockKadriAPI.result.parts.first)
        let rect = PhotoAskGeometry.rect(part.box, imageSize: photo.size, transform: .identity)
        session.select(point: CGPoint(x: rect.midX, y: rect.midY), image: photo, transform: .identity, parts: [part])
        XCTAssertTrue(session.showingSheet)
        return session
    }
    func testLoadingResultErrorAndCancellation() async throws {
        let session = try selectedSession(api: MockKadriAPI())
        XCTAssertEqual(session.phase, .idle)
        session.submit(question: "ეს რა არის?", image: photo, parts: [], context: nil)
        XCTAssertEqual(session.phase, .loading)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(session.phase, .result(MockKadriAPI.askResult))
        session.submit(question: "რა ზომაა?", image: photo, parts: [], context: nil)
        session.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(session.phase, .idle)
        let failed = try selectedSession(api: MockKadriAPI(failure: .unauthorized))
        failed.submit(question: "?", image: photo, parts: [], context: nil)
        try await Task.sleep(for: .milliseconds(200))
        guard case .error = failed.phase else { return XCTFail("Expected error") }
        failed.dismiss()
        XCTAssertNil(failed.selection)
        XCTAssertFalse(failed.showingSheet)
    }
    func testAskSheetSnapshot() async throws {
        let session = try selectedSession(api: MockKadriAPI())
        session.submit(question: "ეს რა არის?", image: photo, parts: [], context: nil)
        try await Task.sleep(for: .milliseconds(200))
        let host = UIHostingController(rootView: PhotoAskSheet(session: session, image: photo, parts: [], context: nil))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        var rendered = false
        let shot = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(rendered)
        let data = try XCTUnwrap(shot.pngData()); XCTAssertGreaterThan(data.count, 1000)
        let directory = URL(fileURLWithPath: "/Users/beqolozi/Developer/kadri-e2e-artifacts/ask-2026-10-18")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("ask-sheet.png"))
        let attachment = XCTAttachment(image: shot); attachment.lifetime = .keepAlways; add(attachment)
    }
}
