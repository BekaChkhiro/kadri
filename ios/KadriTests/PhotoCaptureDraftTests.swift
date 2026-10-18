import SwiftUI
import UIKit
import XCTest
import KadriCore
@testable import Kadri

@MainActor
final class PhotoCaptureDraftTests: XCTestCase {
    private func photo(_ color: UIColor = .red, width: CGFloat = 1200, height: CGFloat = 800) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testFirstCaptureAndAdditionalPhotosKeepFullFrameAndDescription() throws {
        let session = PhotoSession(api: MockKadriAPI())
        session.select(photo())
        session.model.updateText("შეერთებიდან წყალი ჟონავს")
        XCTAssertEqual(session.draftPhotos.first?.role, .overview)
        let first = try XCTUnwrap(session.draftPhotos.first)
        XCTAssertEqual(UIImage(data: first.image)?.size, CGSize(width: 768, height: 512))
        XCTAssertEqual(session.image?.size.width, session.image?.size.height)
        XCTAssertTrue(session.addDraftPhoto(photo(.blue, width: 800, height: 1200)))
        XCTAssertEqual(session.draftPhotos.map(\.role), [.overview, .detail])
        XCTAssertEqual(UIImage(data: try XCTUnwrap(session.selectedDraftPhoto).image)?.size, CGSize(width: 512, height: 768))
        XCTAssertEqual(session.model.phase, .describing(text: "შეერთებიდან წყალი ჟონავს"))
        XCTAssertEqual(session.draftPhotos.first, first)
    }

    func testFivePhotoLimitAndInvalidImageDoNotMutateEvidence() throws {
        let session = PhotoSession(api: MockKadriAPI())
        session.select(photo())
        let firstID = session.selectedDraftPhotoID
        XCTAssertFalse(session.addDraftPhoto(UIImage()))
        XCTAssertEqual(session.draftPhotos.count, 1)
        XCTAssertEqual(session.selectedDraftPhotoID, firstID)
        for _ in 1..<5 { XCTAssertTrue(session.addDraftPhoto(photo())) }
        let evidence = session.draftPhotos
        XCTAssertFalse(session.canAddDraftPhoto)
        XCTAssertFalse(session.addDraftPhoto(photo()))
        XCTAssertEqual(session.draftPhotos, evidence)
        session.model.beginDescribing()
        session.select(UIImage())
        XCTAssertEqual(session.draftPhotos, evidence)
    }

    func testRemovingFirstPhotoKeepsDescriptionAndReplacesLegacyReference() throws {
        let session = PhotoSession(api: MockKadriAPI())
        session.select(photo(.red))
        let initialImage = session.image
        let firstID = try XCTUnwrap(session.draftPhotos.first?.id)
        session.model.updateText("არ ირთვება")
        XCTAssertTrue(session.addDraftPhoto(photo(.blue)))
        let survivor = try XCTUnwrap(session.selectedDraftPhoto)
        session.selectedDraftPhotoID = firstID
        XCTAssertTrue(session.removeDraftPhoto(id: firstID))
        XCTAssertEqual(session.draftPhotos, [survivor])
        XCTAssertEqual(session.selectedDraftPhoto, survivor)
        XCTAssertFalse(session.image === initialImage)
        XCTAssertEqual(session.image?.size.width, session.image?.size.height)
        XCTAssertEqual(session.model.phase, .describing(text: "არ ირთვება"))
        XCTAssertFalse(session.removeDraftPhoto(id: survivor.id))
        XCTAssertFalse(session.removeDraftPhoto(id: "missing"))
    }

    func testRemovingSelectedLastPhotoSelectsPreviousAndRetakeClearsDraft() throws {
        let session = PhotoSession(api: MockKadriAPI())
        session.select(photo())
        let first = try XCTUnwrap(session.selectedDraftPhoto)
        XCTAssertTrue(session.addDraftPhoto(photo(.blue)))
        XCTAssertTrue(session.removeDraftPhoto(id: try XCTUnwrap(session.selectedDraftPhotoID)))
        XCTAssertEqual(session.selectedDraftPhoto, first)
        session.retake()
        XCTAssertTrue(session.draftPhotos.isEmpty)
        XCTAssertNil(session.selectedDraftPhotoID)
        XCTAssertNil(session.selectedDraftPhoto)
        XCTAssertNil(session.image)
        XCTAssertEqual(session.model.phase, .describing(text: ""))
    }

    func testFactoryDefersRequestAndPreservesEvidenceProviderAndInjectedAPI() async throws {
        let api = DraftProblemAPI()
        let session = PhotoSession(api: api)
        session.select(photo())
        XCTAssertTrue(session.addDraftPhoto(photo(.blue)))
        session.model.updateText("ორივე ფოტოზე ერთი მოწყობილობაა")
        let model = session.makeProblemModel(provider: .gemini)
        XCTAssertEqual(model.photos, session.draftPhotos)
        XCTAssertEqual(model.problem, "ორივე ფოტოზე ერთი მოწყობილობაა")
        XCTAssertEqual(model.phase, .draft)
        let before = await api.request
        XCTAssertNil(before)
        await model.submit()
        let submitted = await api.request
        let request = try XCTUnwrap(submitted)
        XCTAssertEqual(request.photos, session.draftPhotos)
        XCTAssertEqual(request.problem, model.problem)
        XCTAssertEqual(request.provider, .gemini)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(session.makeProblemModel(description: "ახალი აღწერა").problem, "ახალი აღწერა")
    }

    func testUnifiedDraftFitsPhoneAndKeepsExistingDescriptionPanel() async throws {
        let session = PhotoSession(api: MockKadriAPI())
        let first = try XCTUnwrap(PhotoArrowDemoScene.image(0))
        session.select(first)
        session.model.updateText("ნიჟარის ქვეშ წყალი წვეთავს")
        try await renderDraft(session, name: "one-photo", height: 844)
        XCTAssertTrue(session.addDraftPhoto(try XCTUnwrap(PhotoArrowDemoScene.image(1))))
        try await renderDraft(session, name: "two-photos", height: 844)
        try await renderDraft(session, name: "compact-keyboard", height: 500)
        XCTAssertEqual(session.model.phase, .describing(text: "ნიჟარის ქვეშ წყალი წვეთავს"))
    }

    private func renderDraft(_ session: PhotoSession, name: String, height: CGFloat) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: NavigationStack { PhotoFlowView(session: session) })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: height)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            XCTAssertTrue(window.drawHierarchy(in: window.bounds, afterScreenUpdates: true))
        }
        let folder = URL(fileURLWithPath: "/tmp/kadri-unified-shots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: folder.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        window.isHidden = true; previous?.makeKeyAndVisible()
    }

    func testSubmissionOpensAnalysisWithoutReenteringDescription() async throws {
        let api = DraftProblemAPI()
        let session = PhotoSession(api: api)
        session.select(photo())
        _ = session.addDraftPhoto(photo(.blue))
        session.model.updateText("ორივე ხედით შეამოწმე პრობლემა")
        let model = session.makeProblemModel(provider: .gemini)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let host = UIHostingController(rootView: PhotoProblemFlowView(model: model, submitOnAppear: true))
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for _ in 0..<50 {
            if model.result != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.problem, "ორივე ხედით შეამოწმე პრობლემა")
        XCTAssertEqual(model.photos.count, 2)
        let count = await api.requestCount
        XCTAssertEqual(count, 1)
    }

    func testStepsMayStartOnSecondPhotoAndRevisitItWithoutReorderingEvidence() async throws {
        let session = PhotoSession(api: ReorderedCaptureAPI())
        session.select(photo())
        _ = session.addDraftPhoto(photo(.blue))
        let model = session.makeProblemModel(description: "ორი ხედი ერთი პრობლემაა")
        let ids = model.photos.map(\.id)
        await model.submit()
        XCTAssertEqual(model.currentStep?.photoId, ids[1])
        await model.markCurrentStep(outcome: .done)
        XCTAssertEqual(model.currentStep?.photoId, ids[0])
        await model.markCurrentStep(outcome: .done)
        XCTAssertEqual(model.currentStep?.photoId, ids[1])
        XCTAssertEqual(model.photos.map(\.id), ids)
        XCTAssertEqual(model.history.map(\.photoId), [ids[1], ids[0]])
    }

    func testDraftEditingIsDisabledAfterSinglePhotoSubmission() {
        let session = PhotoSession(api: MockKadriAPI(scanDelay: .seconds(5)))
        session.select(photo())
        XCTAssertTrue(session.addDraftPhoto(photo(.blue)))
        let photos = session.draftPhotos
        session.submit("პრობლემა")
        XCTAssertFalse(session.canAddDraftPhoto)
        XCTAssertFalse(session.addDraftPhoto(photo()))
        XCTAssertFalse(session.removeDraftPhoto(id: photos[0].id))
        XCTAssertEqual(session.draftPhotos, photos)
        session.retake()
    }
}

private actor DraftProblemAPI: KadriAPI {
    private(set) var request: ProblemRequest?
    private(set) var requestCount = 0
    func problem(_ request: ProblemRequest) async throws -> ProblemResult {
        self.request = request
        requestCount += 1
        return ProblemResult(summary: "საჭიროა დაზუსტება", observations: request.photos.map {
            ProblemObservation(photoId: $0.id, detail: "მოწყობილობის ხედი", relevance: "uncertain")
        }, components: [], links: [], steps: [],
        next: ProblemNext(kind: .needsAnswer, prompt: "ერთი მოწყობილობაა?", reason: "კავშირი დასადასტურებელია"))
    }
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult {
        throw SessionError.server(code: "unexpected", message: "")
    }
    nonisolated func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct ReorderedCaptureAPI: KadriAPI {
    func problem(_ request: ProblemRequest) async throws -> ProblemResult {
        let ids = request.photos.map(\.id)
        return .init(summary: "შეამოწმე სწორი თანმიმდევრობით",
                     observations: ids.map { .init(photoId: $0, detail: "შეერთების ხედი", relevance: "relevant") },
                     components: [.init(id: "joint", name: "შეერთება", views: [
                        .init(photoId: ids[0], box: [100, 100, 400, 400]),
                        .init(photoId: ids[1], box: [500, 500, 800, 800])])], links: [],
                     steps: [ids[1], ids[0], ids[1]].enumerated().map {
                        .init(id: "s\($0.offset)", title: "შემოწმება", text: "შეამოწმე მონიშნული დეტალი", photoId: $0.element, componentIds: ["joint"])
                     }, next: .init(kind: .verify, prompt: "რა შედეგია?", reason: "შეამოწმე შედეგი"))
    }
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult { throw CancellationError() }
    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
