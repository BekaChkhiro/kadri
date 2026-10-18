import SwiftUI
import PhotosUI
import KadriCore

struct PhotoFlowView: View {
    @StateObject private var session: PhotoSession
    @State private var camera = {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--photo-capture-demo")
        #else
        false
        #endif
    }()
    @State private var checkPhotoRequest = false
    /// Presentation and its model change atomically; a separate Boolean can present
    /// a cover whose captured optional model is still nil on the first submission.
    private struct ProblemPresentation: Identifiable {
        let id = UUID()
        let model: ProblemSessionModel
    }
    @State private var problemPresentation: ProblemPresentation?
    @State private var addSource = false
    @State private var draftLibrary = false
    @State private var draftPicked: [PhotosPickerItem] = []
    @State private var importingDraft = false
    @State private var draftImportGeneration = UUID()
    @State private var picked: PhotosPickerItem?
    @State private var launchedDemo = false
    #if DEBUG && targetEnvironment(simulator)
    @State private var autopilot: PhotoAutopilot?
    #endif

    init(session: PhotoSession = PhotoSession()) {
        _session = StateObject(wrappedValue: session)
    }

    var body: some View {
        Group {
            if let image = session.image { flow(image) } else { picker }
        }
        .preferredColorScheme(.light)
        .toolbar(session.image == nil ? .visible : .hidden, for: .navigationBar)
        .onChange(of: session.model.phase) {
            session.phaseChanged()
            if case .steps(_, _, streaming: true) = session.model.phase { checkPhotoRequest = false }
        }
        .fullScreenCover(isPresented: $camera) {
            PhotoCamera(fullFrame: isDescribing) { image in
                use(image)
            }
        }
        .fullScreenCover(item: $problemPresentation) { presentation in
            PhotoProblemFlowView(model: presentation.model, submitOnAppear: true)
        }
        .confirmationDialog("ფოტოს დამატება", isPresented: $addSource, titleVisibility: .visible) {
            if cameraAvailable { Button("გადაიღე კიდევ ერთი ფოტო") { camera = true } }
            Button("აირჩიე გალერეიდან") { draftLibrary = true }
            Button("გაუქმება", role: .cancel) {}
        }
        .photosPicker(isPresented: $draftLibrary, selection: $draftPicked,
                      maxSelectionCount: max(1, 5 - session.draftPhotos.count), selectionBehavior: .ordered, matching: .images)
        .task(id: draftPicked) { await importDraftPhotos() }
        .task(id: picked) {
            guard let picked else { return }
            do {
                guard let data = try await picked.loadTransferable(type: Data.self) else {
                    session.selectionError = "ფოტოს წაკითხვა ვერ მოხერხდა."
                    return
                }
                let prepared = isDescribing ? try ProblemPhotoImport.jpeg(from: data) : data
                guard let image = UIImage(data: prepared) else {
                    session.selectionError = "ფოტოს წაკითხვა ვერ მოხერხდა."
                    return
                }
                try Task.checkCancellation()
                use(image)
                self.picked = nil
            } catch is CancellationError { }
            catch { session.selectionError = "ფოტოს წაკითხვა ვერ მოხერხდა." }
        }
        .alert("ფოტო ვერ ჩაიტვირთა", isPresented: Binding(
            get: { session.selectionError != nil },
            set: { if !$0 { session.selectionError = nil } }
        )) {
            Button("კარგი") { session.selectionError = nil }
        } message: { Text(session.selectionError ?? "") }
        .onAppear {
            #if DEBUG && targetEnvironment(simulator)
            if !launchedDemo && ProcessInfo.processInfo.arguments.contains("--photo-demo") {
                launchedDemo = true
                session.selectDemo()
                session.submit("ნიჟარა ჟონავს")
            }
            if autopilot == nil, let pilot = PhotoAutopilot.fromArguments(session: session) {
                autopilot = pilot
                pilot.start()
            }
            #endif
        }
    }

    /// A photo taken or picked while the model asks for another one starts the next round.
    private func use(_ image: UIImage) {
        if session.model.canContinueWithCheckPhoto {
            checkPhotoRequest = false
            session.continueWithCheckPhoto(image)
        } else if session.model.canContinueWithPhoto { session.continueWithPhoto(image) }
        else if isDescribing && !session.draftPhotos.isEmpty { _ = session.addDraftPhoto(image) }
        else { session.select(image) }
    }

    private var isDescribing: Bool {
        switch session.model.phase { case .idle, .describing: true; default: false }
    }

    private func importDraftPhotos() async {
        guard !draftPicked.isEmpty else { return }
        let generation = draftImportGeneration
        importingDraft = true
        defer { importingDraft = false }
        for item in draftPicked {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                let jpeg = try ProblemPhotoImport.jpeg(from: data)
                guard let image = UIImage(data: jpeg) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                guard generation == draftImportGeneration else { return }
                _ = session.addDraftPhoto(image)
            } catch is CancellationError { return }
            catch { session.selectionError = error.localizedDescription }
        }
        draftPicked = []
    }

    private func resetDraft() {
        draftImportGeneration = UUID()
        draftPicked = []; picked = nil
        session.retake()
    }

    private func submitDraft(provider: AIProvider) {
        guard !importingDraft else { return }
        if session.draftPhotos.count > 1 {
            problemPresentation = ProblemPresentation(model: session.makeProblemModel(provider: provider, description: description))
        } else { session.submit(description, provider: provider) }
    }

    private var continueDemo: (() -> Void)? {
        #if DEBUG && targetEnvironment(simulator)
        session.continueWithDemo
        #else
        nil
        #endif
    }

    private var cameraAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    private var picker: some View {
        PhotoStartView(cameraAvailable: cameraAvailable, takePhoto: { camera = true }, picked: $picked,
                       selectExample: session.selectExample, demo: demo)
    }

    private var demo: (() -> Void)? {
        #if DEBUG && targetEnvironment(simulator)
        session.selectDemo
        #else
        nil
        #endif
    }

    @ViewBuilder private func flow(_ image: UIImage) -> some View {
        switch session.model.phase {
        case .parts(let result):
            resultView(image, result: result, count: session.model.allSteps.count, streaming: true)
        case .steps(let result, _, let streaming):
            if checkPhotoRequest, case .requested(let prompt, let reason) = session.model.checkPhotoPhase {
                photoScreen(image, title: "ფოტოთი შემოწმება") {
                    PhotoRequestCard(round: session.model.round, prompt: prompt, reason: reason,
                        cameraAvailable: cameraAvailable, camera: { camera = true }, picked: $picked,
                        demo: continueDemo, back: { checkPhotoRequest = false })
                }
            } else if streaming, session.model.checkPhotoPhase == .checking {
                photoScreen(image, title: "ფოტოთი შემოწმება") {
                    VStack(spacing: 16) {
                        ProgressView("ვამოწმებ ფოტოს…").font(.kadri(16))
                        Button("გაუქმება", action: session.model.cancel).buttonStyle(SessionButtonStyle(primary: false))
                    }.padding(16)
                }
            } else {
                resultView(image, result: result, count: session.model.allSteps.count, streaming: streaming)
            }
        case .done(let result, _):
            PhotoDoneView(object: result.object, steps: session.model.allSteps, photos: session.model.round,
                          minutes: session.minutes(), thumbnail: image,
                          close: resetDraft, newPhoto: resetDraft,
                          cause: session.model.foundCause, diagnosticSummary: session.model.completionSummary,
                          answers: session.model.answers.count)
        case .scanning(let startedAt):
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let status = SessionPresentation.scanStatus(elapsed: context.date.timeIntervalSince(startedAt))
                let round = session.model.round
                // From round 2 on the header keeps naming the photo; the scan status moves to the subtitle.
                photoScreen(image, title: round > 1 ? "ფოტო \(round)" : status,
                            subtitle: round > 1 ? status : (session.model.instructions.isEmpty ? nil : session.model.instructions),
                            scanning: true) {
                    PhotoScanPanel(startedAt: startedAt, cancel: session.model.cancel)
                }
            }
        default:
            photoScreen(image, title: isDescribing && session.draftPhotos.count > 1 ? "\(session.draftPhotos.count) ფოტო · ერთი პრობლემა" : (session.model.round > 1 ? "ფოტო \(session.model.round)" : "ფოტო"),
                        panelMinimumHeight: isDescribing ? 280 : 210) {
                switch session.model.phase {
                case .idle, .describing:
                    VStack(spacing: 0) {
                        PhotoDraftAttachments(photos: session.draftPhotos, selectedID: session.selectedDraftPhoto?.id,
                            canAdd: session.canAddDraftPhoto && !importingDraft, importing: importingDraft,
                            select: { session.selectedDraftPhotoID = $0 },
                            remove: { _ = session.removeDraftPhoto(id: $0) }, add: { addSource = true })
                            .disabled(importingDraft)
                        PhotoDescribePanel(text: Binding(get: { description }, set: { session.model.updateText($0) }),
                                           submit: submitDraft)
                            .disabled(importingDraft)
                    }
                case .error(let error, _):
                    // A later round's failure keeps the earlier rounds: retry repeats only the last request,
                    // and "წინა ნაბიჯებზე" returns to the previous round's finished steps.
                    let round = session.model.round
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(round > 1 ? "ფოტო \(round) ვერ დამუშავდა" : "ვერ გავაგრძელე")
                                    .font(.kadri(21, weight: .semibold))
                                Text(error.localizedDescription).font(.kadri(14.5))
                                if round > 1 {
                                    Text("წინა \(session.model.stepOffset) ნაბიჯი შენახულია.").font(.kadri(14.5))
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if error == .unauthorized {
                            PhotoAuthActions(retry: session.model.retry)
                        } else {
                            Button("თავიდან", action: session.model.retry).buttonStyle(SessionButtonStyle())
                                .accessibilityHint("ბოლო მოთხოვნას გაიმეორებს")
                        }
                        if round > 1 {
                            Button("წინა ნაბიჯებზე", action: session.model.cancel).buttonStyle(SessionButtonStyle(primary: false))
                        } else {
                            Button("სხვა ფოტო", action: resetDraft).buttonStyle(SessionButtonStyle(primary: false))
                        }
                    }.padding(16)
                default: EmptyView()
                }
            }
        }
    }

    private func photoScreen<Panel: View>(_ image: UIImage, title: String, subtitle: String? = nil, scanning: Bool = false,
                                          panelMinimumHeight: CGFloat = 210,
                                          @ViewBuilder panel: @escaping () -> Panel) -> some View {
        PhotoScreenLayout(title: title, subtitle: subtitle, close: resetDraft,
                          newPhoto: { if isDescribing { if session.canAddDraftPhoto && !importingDraft { addSource = true } } else { resetDraft() } },
                          newPhotoLabel: isDescribing ? "ფოტოს დამატება" : "სხვა ფოტო", panelMinimumHeight: panelMinimumHeight) {
            GeometryReader { proxy in
                let shown = isDescribing ? session.selectedDraftPhoto.flatMap { UIImage(data: $0.image) } ?? image : image
                Image(uiImage: shown).resizable().scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .background(Theme.Colors.ink[800]!)
                    .overlay { if scanning { PhotoScanBeam() } }
                    .overlay(alignment: .topLeading) {
                        if scanning { PhotoChip(text: "ვასკანერებ…", symbol: "scope").padding(12) }
                    }
                    .contentShape(Rectangle())
                    // Tapping the photo closes the description keyboard.
                    .onTapGesture {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
            }
        } panel: {
            panel()
        }
    }

    private var description: String {
        if case .describing(let text) = session.model.phase { return text }
        return ""
    }

    // Reuse the existing photo-request card and its camera/library controls.
    private var displayedContinuation: StepsContinuation? {
        if case .needsCheckPhoto(let prompt, let reason) = session.model.continuation {
            return .needsPhoto(prompt: prompt, reason: reason)
        }
        return session.model.continuation
    }

    private func resultView(_ image: UIImage, result: PartsResult, count: Int,
                            streaming: Bool, completed: Bool = false) -> some View {
        let shown = session.model.displayedResult ?? result
        let earlier = session.model.displayedRound < session.model.round
        return PhotoResultView(image: session.displayedImage ?? image, parts: shown.parts, meshes: session.displayedMeshes,
                        step: session.model.currentStep, index: session.model.currentStepIndex,
                        count: count, streaming: streaming, object: shown.object,
                        segmentationStatus: earlier ? nil : session.segmentationStatus,
                        close: { session.model.cancel(); resetDraft() },
                        previous: session.model.previous, next: session.model.next, finish: session.model.finish,
                        completed: completed, newPhoto: resetDraft,
                        round: session.model.displayedRound, totalRounds: session.model.round,
                        continuation: displayedContinuation, continueCamera: { camera = true },
                        picked: $picked, continueDemo: continueDemo, cameraAvailable: cameraAvailable,
                        canContinueWithAnswer: session.model.canContinueWithAnswer, answer: { value, unit in
                            session.model.continueWithAnswer(value, unit: unit)
                            if session.model.canContinueWithCheckPhoto { checkPhotoRequest = true }
                        })
    }
}
