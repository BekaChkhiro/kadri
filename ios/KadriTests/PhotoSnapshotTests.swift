import XCTest
import SwiftUI
import KadriCore
@testable import Kadri

@MainActor
final class PhotoSnapshotTests: XCTestCase {
    func testPhotoStepsAndWaiting() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"))
        let demo = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        let photo = try XCTUnwrap(PhotoSession.squareJPEG(demo, maxSide: 1536).flatMap(UIImage.init(data:)))
        XCTAssertEqual(photo.size, CGSize(width: 1024, height: 1024))
        let result = MockKadriAPI.toolPreviewResult
        let meshes = result.parts.map { part in
            let b = part.box.map { CGFloat($0) / 1000 }
            let rect = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            let polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                .map { CGPoint(x: $0.x * 1024, y: $0.y * 1024) }
            return TrackedMesh(id: part.id, mesh: MeshTriangulation.triangulate(polygons: [polygon]), referenceBox: rect)
        }
        let directory = URL(fileURLWithPath: "/tmp/kadri-photo-shots-square/result")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // A rotated copy: still square, but the parts sit elsewhere — focus must not depend on orientation.
        let landscape = UIGraphicsImageRenderer(size: CGSize(width: photo.size.height, height: photo.size.width)).image { context in
            context.cgContext.translateBy(x: photo.size.height, y: 0)
            context.cgContext.rotate(by: .pi / 2)
            photo.draw(in: CGRect(origin: .zero, size: photo.size))
        }
        for index in 0...10 {
            let request = index == 10
            let waiting = index == 5
            let completed = index == 6
            let stepIndex = request ? 2 : min(index, MockKadriAPI.sampleSteps.count - 1)
            let emptyFocus = index == 7 || index == 8
            let step = emptyFocus ? Step(index: 5, title: "გადაამოწმე გაჟონვა", text: "მთელი ფოტო ჩანს. შეამოწმე ყველა შეერთება.", focus: []) : MockKadriAPI.sampleSteps[stepIndex]
            let screen = PhotoResultView(image: index == 8 ? landscape : photo, parts: result.parts, meshes: waiting ? [] : meshes,
                step: waiting ? nil : step, index: waiting ? 0 : stepIndex,
                count: waiting ? 0 : request ? 3 : MockKadriAPI.sampleSteps.count, streaming: waiting || index == 9, object: result.object,
                segmentationStatus: waiting ? "ვასკანერებ…" : nil,
                close: {}, previous: {}, next: {}, finish: {}, completed: completed,
                continuation: request ? .needsPhoto(prompt: MockKadriAPI.round2Prompt, reason: "შუასადების მდგომარეობა ამ ფოტოზე არ ჩანს.") : nil,
                initiallyShowingPhotoRequest: request)
                .environment(\.meshWrapReduceMotion, true)
            let host = UIHostingController(rootView: screen)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.frame = window.bounds
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(1500))
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let data = try XCTUnwrap(image.pngData())
            XCTAssertGreaterThan(data.count, 1000)
            let name = request ? "photo-request" : index == 7 ? "empty-focus-portrait" : index == 8 ? "empty-focus-landscape" : index == 9 ? "preparing-next" : completed ? "done" : waiting ? "waiting" : index == 4 ? "step-last" : "step-\(index + 1)"
            try data.write(to: directory.appendingPathComponent("\(name).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            previousWindow?.makeKeyAndVisible()
        }
    }

    /// A step with every optional field: the warning must render on the first screen, not below the fold.
    func testLongStepKeepsWarningVisible() async throws {
        let warn = "ძალას ნუ დაატან: პლასტმასის ქანჩი ადვილად სკდება, დაზიანებული ხრახნი კი მერე გაჟონვას გამოიწვევს."
        let step = Step(index: 3, title: "მოხსენი სიფონის ქანჩი",
                        text: "გამორთე წყლის მიწოდება ონკანის ქვეშ, მერე ქანჩი საათის ისრის საწინააღმდეგოდ ნელა მოატრიალე, სანამ მილი თავისუფლად არ გამოვა.",
                        warn: warn,
                        tip: "ქანჩის ქვეშ პატარა ვედრო ან ტილო დადე — მილში დარჩენილი წყალი აუცილებლად დაიღვრება კარადის ძირზე.",
                        icon: "unscrew",
                        toolItems: [StepTool(label: "გასაღები", icon: "wrench"), StepTool(label: "ვედრო", icon: "bucket"),
                                    StepTool(label: "ტილო", icon: "towel")])
        let image = try await render(screen(step: step, index: 3, count: 5), name: "step-long-warn")
        // The warning box fill (#fef2f2) must cover at least two lines of text, not a clipped sliver above the buttons.
        let rows = Self.rows(in: image, matching: (254, 242, 242))
        XCTAssertGreaterThanOrEqual(CGFloat(rows) / image.scale, 40, "warning box is clipped or hidden")
    }

    func testByHandOnlyCard() async throws {
        let hands: [StepHand] = [.init(part: "p2", grip: "turn", hand: "right", byHandOnly: true)]
        let step = Step(index: 1, title: "მოუშვი ხელით", text: "ნელა მოატრიალე. ძალას ნუ დაატან.", hands: hands)
        XCTAssertTrue(PhotoByHandCard.isVisible(for: step))
        XCTAssertTrue(PhotoByHandCard.isVisible(for: Step(index: 1, title: "", text: "", toolCards: [], hands: hands)))
        XCTAssertFalse(PhotoByHandCard.isVisible(for: Step(index: 1, title: "", text: "", toolCards: [MockKadriAPI.seenTool], hands: hands)))
        XCTAssertFalse(PhotoByHandCard.isVisible(for: Step(index: 1, title: "", text: "")))
        _ = try await render(screen(step: step, index: 0, count: 2)
            .environment(\.photoOverlayReduceMotion, true), name: "hands-by-hand-card")
    }

    func testToolCardsSeenAndTypical() async throws {
        for large in [false, true] {
            let view = ScrollView {
                VStack(spacing: 12) {
                    PhotoToolCard(tool: MockKadriAPI.seenTool)
                    PhotoToolCard(tool: MockKadriAPI.typicalTool)
                }.padding(16)
            }
            .background(Theme.Colors.surface)
            .environment(\.dynamicTypeSize, large ? .accessibility2 : .large)
            _ = try await render(view, name: large ? "tools-accessibility" : "tools-seen-typical")
        }
    }

    func testToolTipTypes() async throws {
        _ = try await render(ScrollView {
            VStack(spacing: 10) {
                ForEach([("ph2", "PH2"), ("torx_t20", "T20"), ("flat_small", "5 მმ")], id: \.0) { id, size in
                    PhotoToolCard(tool: .init(id: id, size: size, why: "მჭიდროდ უნდა მოერგოს", sizeSource: "model"))
                }
            }.padding(16)
        }.background(Theme.Colors.surface), name: "tools-tip-types")
    }

    func testActionsReduceMotionAndFrames() async throws {
        let boxes = ["p1": CGRect(x: 70, y: 140, width: 50, height: 50),
                     "p2": CGRect(x: 260, y: 140, width: 50, height: 50),
                     "p3": CGRect(x: 70, y: 310, width: 50, height: 50),
                     "p4": CGRect(x: 260, y: 310, width: 50, height: 50)]
        let turn = StepAction(part: "p1", kind: "rotate_ccw", amount: "¼")
        let order = StepAction(part: "p2", kind: "tighten_order", order: ["p1", "p4", "p2", "p3"])
        XCTAssertEqual(PhotoActionOverlays.affectedParts([turn, order], boxes: boxes), Set(boxes.keys))
        XCTAssertTrue(PhotoActionOverlays.affectedParts([.init(part: "p1", kind: "unknown")], boxes: boxes).isEmpty)
        XCTAssertTrue(PhotoActionOverlays.affectedParts([.init(part: "p1", kind: "tighten_order")], boxes: boxes).isEmpty)
        XCTAssertTrue(PhotoActionOverlays.affectedParts([.init(part: "missing", kind: "press")], boxes: boxes).isEmpty)
        for (name, actions) in [("rotate-quarter-reduce-motion", [turn]), ("tighten-order-reduce-motion", [order])] {
            _ = try await render(PhotoActionOverlays(actions: actions, boxes: boxes)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.ink[800]!)
                .environment(\.photoOverlayReduceMotion, true), name: name)
        }
        for (index, progress) in [CGFloat(0.2), 0.6, 1].enumerated() {
            _ = try await render(ZStack(alignment: .topLeading) {
                PhotoActionFrame(action: turn, boxes: boxes, progress: progress)
                PhotoActionFrame(action: order, boxes: boxes.mapValues { $0.offsetBy(dx: 0, dy: 260) }, progress: progress)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.ink[800]!), name: "actions-frame-\(index)")
        }
    }

    func testLongStepToolsTipAndWarningScrollAboveFooter() async throws {
        let tool = StepToolCard(id: "open_wrench", size: "10 მმ", why: "ქანჩის მოსაშვებად",
            notThis: .init(id: "pliers", reason: "ქანჩის კიდეებს დააზიანებს. ძალას ნუ დაატან."),
            fitCheck: MockKadriAPI.typicalTool.fitCheck, alternatives: ["11 მმ"])
        let step = Step(index: 2, title: "შეამოწმე სამაგრი",
            text: "მოარგე ხელსაწყო სამაგრს. ზომა ჯერ შეამოწმე და მხოლოდ შემდეგ მოუშვი ნელა. " +
                  "თუ ხელსაწყო თავისუფლად ბრუნავს ან ჭრილიდან ამოდის, გაჩერდი და სხვა ზომა სცადე.",
            warn: "ძალას ნუ დაატან: შეუსაბამო ზომა სამაგრს დააზიანებს.",
            tip: "შეინახე მოხსნილი ნაწილები თანმიმდევრობით, რომ აწყობისას არცერთი არ გამოგრჩეს.",
            icon: "unscrew", toolCards: [MockKadriAPI.seenTool, tool])
        let view = screen(step: step, index: 1, count: 3).environment(\.photoOverlayReduceMotion, true)
        _ = try await render(view, name: "tools-long-step-top")
        let image = try await render(view, name: "tools-long-step-bottom") { window in
            let scrolls = Self.descendants(window).compactMap { $0 as? UIScrollView }
            let scroll = try XCTUnwrap(scrolls.max(by: { $0.contentSize.height < $1.contentSize.height }))
            let bottom = scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom
            XCTAssertGreaterThan(bottom, 100, "Fixture must require scrolling")
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            scroll.layoutIfNeeded()
            XCTAssertEqual(scroll.contentOffset.y, bottom, accuracy: 1)
        }
        XCTAssertGreaterThan(CGFloat(Self.rows(in: image, matching: (254, 242, 242))) / image.scale, 40,
                             "The last tool's complete warning must remain visible above the footer")
    }

    private static func descendants(_ view: UIView) -> [UIView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    func testDiagnosticCardsAndSummary() async throws {
        for (name, continuation) in [("answer-card", MockKadriAPI.answerRequest), ("measurement-card", MockKadriAPI.measurementRequest)] {
            _ = try await render(screen(step: MockKadriAPI.sampleSteps[2], index: 2, count: 3, continuation: continuation), name: name)
        }
        _ = try await render(PhotoDoneView(object: "დიაგნოსტიკა", steps: Array(MockKadriAPI.sampleSteps.prefix(3)),
            photos: 1, minutes: 2, thumbnail: nil, close: {}, newPhoto: {},
            cause: "პარაზიტული დენი სალონის განათებიდან", diagnosticSummary: "მცველი F12 ამოღებისას დენი 30 mA-მდე დაეცა.", answers: 2), name: "done-cause")
    }

    func testLongPhotoRequestChecklist() async throws {
        let prompt = "გადაუღე სიფონის ქვედა შეერთებას ახლოდან, ქანჩი რომ ჩანდეს"
        let reason = "ამ ფოტოზე შუასადების მდგომარეობა არ ჩანს, ამიტომ ვერ ვიტყვი, გამოსაცვლელია თუ საკმარისია მხოლოდ მოჭერა."
        let screen = screen(step: MockKadriAPI.sampleSteps[2], index: 2, count: 3,
                            continuation: .needsPhoto(prompt: prompt, reason: reason))
        let image = try await render(screen, name: "photo-request-long")
        XCTAssertGreaterThan(image.size.height, 0)
    }

    private func screen(step: Step, index: Int, count: Int, continuation: StepsContinuation? = nil) -> some View {
        let result = MockKadriAPI.toolPreviewResult
        let url = Bundle.main.url(forResource: "PhotoDemo", withExtension: "png")!
        let photo = PhotoSession.squareJPEG(UIImage(contentsOfFile: url.path)!, maxSide: 1536).flatMap(UIImage.init(data:))!
        return PhotoResultView(image: photo, parts: result.parts, meshes: [], step: step, index: index, count: count,
                               streaming: false, object: result.object, segmentationStatus: nil,
                               close: {}, previous: {}, next: {}, finish: {},
                               continuation: continuation, initiallyShowingPhotoRequest: continuation != nil,
                               canContinueWithAnswer: true, initiallyShowingAnswerRequest: true)
            .environment(\.meshWrapReduceMotion, true)
    }

    /// Renders a full-screen window like the step snapshots above and writes it beside them.
    private func render(_ view: some View, name: String, interact: ((UIWindow) throws -> Void)? = nil) async throws -> UIImage {
        let directory = URL(fileURLWithPath: "/tmp/kadri-photo-shots-square/result")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(1500))
        try interact?(window)
        try await Task.sleep(for: .milliseconds(100))
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(rendered)
        let data = try XCTUnwrap(image.pngData())
        try data.write(to: directory.appendingPathComponent("\(name).png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        previousWindow?.makeKeyAndVisible()
        return image
    }

    /// Pixel rows in which a wide run (≥ 100 px) has the given colour.
    private static func rows(in image: UIImage, matching rgb: (Int, Int, Int)) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var count = 0
        for y in 0..<height {
            var run = 0
            for x in 0..<width {
                let i = (y * width + x) * 4
                if abs(Int(pixels[i]) - rgb.0) <= 3 && abs(Int(pixels[i + 1]) - rgb.1) <= 3 && abs(Int(pixels[i + 2]) - rgb.2) <= 3 { run += 1 } else { run = 0 }
                if run >= 100 { count += 1; break }
            }
        }
        return count
    }
}


extension PhotoSnapshotTests {
    func testCaptureBeforeAndAfterShot() async throws {
        #if targetEnvironment(simulator)
        let camera = PhotoCaptureCamera()
        let host = UIHostingController(rootView: PhotoCamera(camera: camera, selected: { _ in }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            camera.stop()
            window.isHidden = true
            window.rootViewController = nil
            window.windowScene = nil
            previous?.makeKeyAndVisible()
        }
        let directory = URL(fileURLWithPath: "/tmp/kadri-capture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["before-shot", "after-shot"] {
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertTrue(camera.ready)
            if name == "after-shot" {
                camera.capture()
                XCTAssertNotNil(camera.image)
                XCTAssertEqual(camera.image?.size.width, camera.image?.size.height)
                XCTAssertEqual(camera.image?.imageOrientation, .up)
                try await Task.sleep(for: .milliseconds(500))
            } else {
                XCTAssertNil(camera.image)
            }
            var rendered = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent("snapshot-\(name).png"))
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let first = try XCTUnwrap(camera.image)
        camera.capture()
        XCTAssertNotNil(camera.image)
        XCTAssertFalse(first === camera.image, "Retake must replace the frozen frame")
        #endif
    }

    func testCaptureSquareNormalizesEveryEXIFOrientation() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4), format: format).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            UIColor.red.setFill()
            context.fill(CGRect(x: 2, y: 0, width: 4, height: 2))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 2, y: 2, width: 4, height: 2))
        }
        let cg = try XCTUnwrap(source.cgImage)
        // Expected red sample after applying each EXIF rotation/mirroring.
        let cases: [(UIImage.Orientation, CGPoint)] = [
            (.up, CGPoint(x: 1, y: 0)), (.upMirrored, CGPoint(x: 1, y: 0)),
            (.down, CGPoint(x: 1, y: 3)), (.downMirrored, CGPoint(x: 1, y: 3)),
            (.left, CGPoint(x: 0, y: 1)), (.right, CGPoint(x: 3, y: 1)),
            (.leftMirrored, CGPoint(x: 0, y: 1)), (.rightMirrored, CGPoint(x: 3, y: 1))
        ]
        for (orientation, redPoint) in cases {
            let cropped = PhotoCaptureCamera.square(UIImage(cgImage: cg, scale: 1, orientation: orientation))
            XCTAssertEqual(cropped.size, CGSize(width: 4, height: 4))
            XCTAssertEqual(cropped.imageOrientation, .up)
            let pixels = try XCTUnwrap(cropped.cgImage)
            var rgba = [UInt8](repeating: 0, count: 4 * 4 * 4)
            let context = try XCTUnwrap(CGContext(data: &rgba, width: 4, height: 4, bitsPerComponent: 8,
                bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixels, in: CGRect(x: 0, y: 0, width: 4, height: 4))
            let offset = (Int(redPoint.y) * 4 + Int(redPoint.x)) * 4
            XCTAssertGreaterThan(rgba[offset], 240, "Red must rotate correctly: \(orientation)")
            for offset in stride(from: 0, to: rgba.count, by: 4) {
                XCTAssertLessThan(rgba[offset + 1], 10, "Green edges must be outside the central crop")
            }
        }
    }
}
