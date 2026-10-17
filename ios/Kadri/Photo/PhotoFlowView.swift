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
            Color.clear.background {
                GeometryReader { proxy in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                                .frame(height: 150)
                        }
                }.ignoresSafeArea().ignoresSafeArea(.keyboard)
            }
            .overlay {
                if case .scanning(let startedAt) = session.model.phase {
                    ScanningView(startedAt: startedAt, cancel: session.model.cancel)
                }
            }
            .safeAreaInset(edge: .top) {
                HStack {
                    Button(action: session.retake) {
                        Image(systemName: "xmark").frame(width: 44, height: 44).glass(radius: 22)
                    }.foregroundStyle(Theme.Colors.ink[900]!).accessibilityLabel("დახურვა")
                    Spacer()
                }.padding(.horizontal, 16).padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom) {
                VStack {
                    switch session.model.phase {
                    case .idle, .describing:
                        DescribeBar(text: Binding(get: { description }, set: { session.model.updateText($0) })) {
                            session.submit(description)
                        }
                    case .error(let error, _):
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ვერ გავაგრძელე").font(.kadri(21, weight: .semibold))
                            Text(error.localizedDescription).font(.kadri(14.5))
                            Button("თავიდან", action: session.model.retry).buttonStyle(SessionButtonStyle())
                            Button("სხვა ფოტო", action: session.retake).buttonStyle(SessionButtonStyle(primary: false))
                        }.padding(16).glass()
                    default: EmptyView()
                    }
                }.padding(.horizontal, 12).padding(.vertical, 8)
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
