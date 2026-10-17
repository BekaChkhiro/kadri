import SwiftUI
import PhotosUI
import KadriCore

struct PhotoFlowView: View {
    @StateObject private var session = PhotoSession()
    @State private var camera = false
    @State private var picked: PhotosPickerItem?
    @State private var launchedDemo = false

    var body: some View {
        Group {
            if let image = session.image { flow(image) } else { picker }
        }
        .preferredColorScheme(.light)
        .toolbar(session.image == nil ? .visible : .hidden, for: .navigationBar)
        .onChange(of: session.model.phase) { session.phaseChanged() }
        .fullScreenCover(isPresented: $camera) {
            PhotoCamera(selected: session.select).ignoresSafeArea()
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
                session.select(image)
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
            #endif
        }
    }

    private var cameraAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        UIImagePickerController.isSourceTypeAvailable(.camera)
        #endif
    }

    private var picker: some View {
        ZStack {
            Theme.Colors.surface.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 40)).foregroundStyle(Theme.Colors.brand[500]!)
                Text("გადაიღე ან აირჩიე ფოტო").font(.kadri(26, weight: .semibold))
                Text("კადრი ნაწილებს იპოვის და ნაბიჯ-ნაბიჯ გეტყვის რა გააკეთო")
                    .font(.kadri(15)).foregroundStyle(Theme.Colors.ink[600]!)
                Button("გადაღება") { camera = true }
                    .buttonStyle(SessionButtonStyle(primary: true))
                    .disabled(!cameraAvailable)
                if !cameraAvailable {
                    Text("ამ მოწყობილობაზე კამერა არ არის")
                        .font(.kadri(12)).foregroundStyle(Theme.Colors.ink[500]!)
                }
                PhotosPicker(selection: $picked, matching: .images) { Text("გალერეიდან") }
                    .buttonStyle(SessionButtonStyle(primary: false))
                #if DEBUG && targetEnvironment(simulator)
                Button("სატესტო ფოტო", action: session.selectDemo)
                    .buttonStyle(SessionButtonStyle(primary: false))
                #endif
            }
            .foregroundStyle(Theme.Colors.ink[900]!)
            .padding(24).glass().padding(20)
        }
    }

    @ViewBuilder private func flow(_ image: UIImage) -> some View {
        switch session.model.phase {
        case .parts(let result):
            resultView(image, result: result, count: 0, streaming: true)
        case .steps(let result, let steps, let streaming):
            resultView(image, result: result, count: steps.count, streaming: streaming)
        case .done(let result, let steps):
            resultView(image, result: result, count: steps.count, streaming: false, completed: true)
        default:
            PhotoScreenLayout(title: "ფოტო", close: session.retake, newPhoto: session.retake) {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .background(Theme.Colors.ink[800]!)
                }
            } panel: {
                switch session.model.phase {
                case .idle, .describing:
                    DescribeBar(text: Binding(get: { description }, set: { session.model.updateText($0) }), inPhotoPanel: true) {
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
                        Button("თავიდან", action: session.model.retry).buttonStyle(SessionButtonStyle())
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
        PhotoResultView(image: image, parts: result.parts, meshes: session.meshes,
                        step: session.model.currentStep, index: session.model.currentStepIndex,
                        count: count, streaming: streaming, object: result.object,
                        segmentationStatus: session.segmentationStatus,
                        close: { session.model.cancel(); session.retake() },
                        previous: session.model.previous, next: session.model.next, finish: session.model.finish,
                        completed: completed, newPhoto: session.retake)
    }
}
