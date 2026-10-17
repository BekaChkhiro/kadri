import SwiftUI
import PhotosUI
import KadriCore

struct PhotoFlowView: View {
    @StateObject private var session: PhotoSession
    @State private var camera = false
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
        .onChange(of: session.model.phase) { session.phaseChanged() }
        .fullScreenCover(isPresented: $camera) {
            PhotoCamera(selected: use).ignoresSafeArea()
        }
        .task(id: picked) {
            guard let picked else { return }
            do {
                guard let data = try await picked.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
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
        if session.model.canContinueWithPhoto { session.continueWithPhoto(image) } else { session.select(image) }
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
            resultView(image, result: result, count: session.model.allSteps.count, streaming: streaming)
        case .done(let result, _):
            resultView(image, result: result, count: session.model.allSteps.count, streaming: false, completed: true)
        default:
            PhotoScreenLayout(title: session.model.round > 1 ? "ფოტო \(session.model.round)" : "ფოტო", close: session.retake, newPhoto: session.retake) {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .background(Theme.Colors.ink[800]!)
                }
            } panel: {
                switch session.model.phase {
                case .idle, .describing:
                    PhotoDescribePanel(text: Binding(get: { description }, set: { session.model.updateText($0) })) {
                        session.submit(description)
                    }
                case .scanning(let startedAt):
                    VStack(spacing: 16) {
                        ScrollView {
                            VStack(spacing: 16) {
                                ProgressView().tint(Theme.Colors.brand[500]!)
                                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                                    Text(SessionPresentation.scanStatus(elapsed: context.date.timeIntervalSince(startedAt)))
                                        .font(.kadri(18, weight: .semibold))
                                }
                            }.frame(maxWidth: .infinity).padding(.top, 24)
                        }
                        Button("გაუქმება", action: session.model.cancel)
                            .buttonStyle(SessionButtonStyle(primary: false))
                    }.padding(16)
                case .error(let error, _):
                    VStack(alignment: .leading, spacing: 12) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("ვერ გავაგრძელე").font(.kadri(21, weight: .semibold))
                                Text(error.localizedDescription).font(.kadri(14.5))
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if error == .unauthorized {
                            PhotoAuthActions(retry: session.model.retry)
                        } else {
                            Button("თავიდან", action: session.model.retry).buttonStyle(SessionButtonStyle())
                        }
                        Button("სხვა ფოტო", action: session.retake).buttonStyle(SessionButtonStyle(primary: false))
                    }.padding(16)
                default: EmptyView()
                }
            }
        }
    }

    private var description: String {
        if case .describing(let text) = session.model.phase { return text }
        return ""
    }

    private func resultView(_ image: UIImage, result: PartsResult, count: Int,
                            streaming: Bool, completed: Bool = false) -> some View {
        let shown = session.model.displayedResult ?? result
        let earlier = session.model.displayedRound < session.model.round
        return PhotoResultView(image: session.displayedImage ?? image, parts: shown.parts, meshes: session.displayedMeshes,
                        step: session.model.currentStep, index: session.model.currentStepIndex,
                        count: count, streaming: streaming, object: shown.object,
                        segmentationStatus: earlier ? nil : session.segmentationStatus,
                        close: { session.model.cancel(); session.retake() },
                        previous: session.model.previous, next: session.model.next, finish: session.model.finish,
                        completed: completed, newPhoto: session.retake,
                        round: session.model.displayedRound, totalRounds: session.model.round,
                        continuation: session.model.continuation, continueCamera: { camera = true },
                        picked: $picked, continueDemo: continueDemo, cameraAvailable: cameraAvailable)
    }
}
