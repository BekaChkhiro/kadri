import XCTest
import SwiftUI
import QuartzCore
import KadriCore
@testable import Kadri

private final class MeshDrawSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func append(_ value: Double) { lock.lock(); values.append(value); lock.unlock() }
    func read() -> [Double] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
private final class MeshTestModel: ObservableObject {
    @Published var state: MeshWrap.State = .idle
    @Published var offset: CGSize = .zero
    @Published var appeared = true
}

private struct MeshTestHost: View {
    let fixture: MeshWrapFixture
    @ObservedObject var model: MeshTestModel
    let reduced: Bool
    let samples: MeshDrawSamples
    var body: some View {
        MeshWrapFixtureView(fixture: fixture,state: model.state,appeared: model.appeared,offset: model.offset)
            .environment(\.meshWrapReduceMotion,reduced)
            .environment(\.meshWrapDrawObserver, { samples.append($0) })
            .frame(maxWidth: .infinity,maxHeight: .infinity,alignment: .top)
            .background(Theme.Colors.surface)
    }
}

@MainActor
final class MeshWrapSnapshotTests: XCTestCase {
    private func host(_ root: some View) throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: root)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    private func capture(_ window: UIWindow, name: String) throws -> Data {
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds,afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: URL(fileURLWithPath: "/tmp/kadri-meshwrap-\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = "kadri-meshwrap-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return data
    }

    func testHostedStatesAndTransformDrawBudget() async throws {
        let fixture = try MeshWrapFixture.load()
        XCTAssertEqual(fixture.meshes.count,5)
        XCTAssertTrue(fixture.meshes.allSatisfy { $0.triangleCount > 0 && $0.triangleCount <= 600 })
        let model = MeshTestModel(), samples = MeshDrawSamples()
        let window = try host(MeshTestHost(fixture: fixture,model: model,reduced: true,samples: samples))
        defer { window.isHidden = true }
        var previous: Data?
        for state in MeshWrap.State.allCases {
            model.state = state
            try await Task.sleep(for: .milliseconds(350))
            let data = try capture(window,name: state.rawValue)
            if let previous { XCTAssertNotEqual(previous,data,"State changes must reach the hosted Canvas") }
            previous = data
        }
        // Exercise transform-only updates of already cached geometry.
        for index in 0..<24 {
            model.offset = CGSize(width: CGFloat(index%6),height: CGFloat(index%4))
            try await Task.sleep(for: .milliseconds(20))
        }
        let values = samples.read().dropFirst(5).sorted()
        XCTAssertGreaterThan(values.count,20,"The real Canvas closure must have run")
        let median = values[values.count/2], p95 = values[min(values.count-1,Int(Double(values.count)*0.95))]
        print("MeshWrap Canvas CPU encoding: median \(median) ms, p95 \(p95) ms, n=\(values.count); GPU time excluded")
        XCTAssertLessThanOrEqual(p95,2,"Per-mesh Canvas command-encoding budget")
    }

    func testScanReappearanceAndReducedMotion() async throws {
        let fixture = try MeshWrapFixture.load()
        let model = MeshTestModel(), samples = MeshDrawSamples()
        let window = try host(MeshTestHost(fixture: fixture,model: model,reduced: false,samples: samples))
        defer { window.isHidden = true }
        try await Task.sleep(for: .milliseconds(400))
        let scanning = try capture(window,name: "scan")
        try await Task.sleep(for: .milliseconds(1200))
        let complete = try capture(window,name: "complete")
        XCTAssertNotEqual(scanning,complete)
        model.appeared = false
        try await Task.sleep(for: .milliseconds(150))
        let hidden = try capture(window,name: "hidden")
        XCTAssertNotEqual(hidden,complete)
        model.appeared = true
        try await Task.sleep(for: .milliseconds(1600))
        let replayed = try capture(window,name: "replayed")
        XCTAssertEqual(complete,replayed,"The one-shot scan must settle to the same geometry")
    }
}
