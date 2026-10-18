import SwiftUI
import PhotosUI
import KadriCore

/// A problem owns its evidence; each instruction is rendered only on its referenced photo.
struct PhotoProblemFlowView: View {
    @State private var model: ProblemSessionModel
    private let isDemo: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var importing = false
    @State private var importError: String?
    @State private var selectedID: String?
    @State private var answer = ""
    @State private var stepNote = ""
    @State private var operation: Task<Void, Never>?

    init(model: ProblemSessionModel? = nil, isDemo: Bool = false) {
        _model = State(initialValue: model ?? Self.liveModel())
        self.isDemo = isDemo
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if isDemo {
                        Label("სატესტო სცენარი · AI-ს არ უკავშირდება", systemImage: "testtube.2")
                            .font(.kadri(12)).foregroundStyle(.secondary)
                    }
                    intro.id("top")
                    if !model.photos.isEmpty { photoStrip.id("evidence") }
                    if let photo = selectedPhoto {
                        ProblemEvidenceView(photo: photo, result: model.result, step: model.currentStep)
                            .frame(height: model.hasSubmitted ? 220 : 240).clipShape(RoundedRectangle(cornerRadius: 20))
                        photoEditor(photo)
                    }
                    if model.canAddPhoto && !model.hasSubmitted { addPhotos }
                    if let importError { Text(importError).foregroundStyle(.red).font(.kadri(13)) }
                    if model.isLoading {
                        HStack { ProgressView(); Text("ფოტოებსა და ნაბიჯებს ვაკავშირებ…").font(.kadri(14)) }
                        Button("შეწყვეტა") { operation?.cancel(); model.cancel() }
                    } else if let error = model.errorMessage {
                        Text(error).font(.kadri(14)).foregroundStyle(.red)
                        action("ხელახლა ცდა") { await model.retry() }
                    }
                    if model.hasSubmitted && model.hasPendingPhotos && !model.isLoading && model.phase != .error {
                        action("დამატებული ფოტოებით განახლება") { await model.submit() }
                        Text("ახალი ფოტოებით გეგმა ხელახლა შემოწმდება.").font(.kadri(12)).foregroundStyle(.secondary)
                    }
                    if let result = model.result {
                        if let step = model.currentStep { stepCard(step).id("progress").disabled(model.hasPendingPhotos || importing) }
                        if let next = model.continuation { continuation(next).id("progress") }
                        evidenceSummary(result)
                    }
                    if model.canAddPhoto && model.hasSubmitted { addPhotos }
                    if !model.history.isEmpty { history }
                }.padding(20)
            }
            .onChange(of: model.sessionId) { _, _ in scroller.scrollTo("top", anchor: .top) }
            .onChange(of: model.currentStep?.id) { _, value in
                withAnimation { scroller.scrollTo(value == nil ? "progress" : "evidence", anchor: .top) }
            }
            }
            .safeAreaInset(edge: .bottom) {
                if !model.hasSubmitted && !model.isLoading && model.errorMessage == nil {
                    action("შეადგინე ნაბიჯები") { await model.submit() }
                        .disabled(importing || model.photos.isEmpty || model.problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .padding(.horizontal, 20).padding(.vertical, 10).background(Theme.Colors.surface)
                }
            }
            .background(Theme.Colors.surface).foregroundStyle(Theme.Colors.ink[900]!)
            .navigationTitle("ერთი პრობლემა")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isDemo ? "თავიდან" : "დახურვა") {
                        #if DEBUG
                        if isDemo {
                            operation?.cancel(); model.cancel()
                            model = PhotoProblemDemo.model()
                            selectedID = nil; answer = ""; stepNote = ""; importError = nil; picked = []
                            return
                        }
                        #endif
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $camera) {
                PhotoCamera(fullFrame: true) { image in
                    do { append(try ProblemPhotoImport.jpeg(from: image)) }
                    catch { importError = error.localizedDescription }
                }
            }
            .task(id: picked) { await importSelection() }
            .onChange(of: model.currentStep?.id) { _, _ in
                if let step = model.currentStep { selectedID = step.photoId }
                stepNote = ""
            }
            .onAppear { if selectedID == nil { selectedID = model.currentStep?.photoId } }
            .onDisappear { if !camera { operation?.cancel() } }
        }.preferredColorScheme(.light)
    }

    private var selectedPhoto: ProblemPhoto? { model.photos.first { $0.id == selectedID } ?? model.photos.first }
    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.hasSubmitted ? model.problem : "აჩვენე პრობლემა სხვადასხვა მხრიდან")
                .font(.kadri(model.hasSubmitted ? 18 : 23, weight: .semibold))
            if !model.hasSubmitted {
                Text("დაამატე საერთო ხედი, დეტალი ან წარწერა. ყველა ფოტო ერთ პრობლემას უნდა აღწერდეს.")
                    .font(.kadri(14)).foregroundStyle(.secondary)
                TextField("რა არ მუშაობს და რის მიღწევა გინდა?", text: Binding(
                    get: { model.problem }, set: { model.problem = String($0.prefix(1000)) }), axis: .vertical)
                    .lineLimit(2...5).font(.kadri(15)).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .disabled(model.isLoading)
                    .accessibilityIdentifier("problem.description")
            }
        }
    }
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, photo in
                    Button { selectedID = photo.id } label: {
                        VStack(spacing: 5) {
                            if let image = UIImage(data: photo.image) {
                                Image(uiImage: image).resizable().scaledToFill().frame(width: 76, height: 68).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selectedPhoto?.id == photo.id ? Theme.Colors.brand[500]! : .clear, lineWidth: 3))
                            }
                            Text("ფოტო \(index + 1)").font(.kadri(12, weight: .medium))
                        }
                    }.buttonStyle(.plain).accessibilityIdentifier("problem.photo.\(index + 1)")
                }
            }.padding(3)
        }
    }
    @ViewBuilder private func photoEditor(_ photo: ProblemPhoto) -> some View {
        if model.canEditPhoto(id: photo.id) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("ფოტოს ტიპი", selection: Binding(get: { photo.role }, set: { _ = model.updatePhoto(id: photo.id, note: photo.note, role: $0) })) {
                    ForEach(ProblemPhoto.Role.allCases, id: \.self) { Text($0 == .overview ? "საერთო" : $0.georgianTitle).tag($0) }
                }.pickerStyle(.segmented)
                TextField("რა ჩანს ამ ფოტოზე? (არასავალდებულო)", text: Binding(get: { photo.note }, set: { _ = model.updatePhoto(id: photo.id, note: String($0.prefix(300)), role: photo.role) }), axis: .vertical)
                    .font(.kadri(14)).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                Button("ამ ფოტოს წაშლა", role: .destructive) { _ = model.removePhoto(id: photo.id) }.font(.kadri(12))
            }
        } else {
            Text(photo.role.georgianTitle + (photo.note.isEmpty ? "" : " · " + photo.note))
                .font(.kadri(13)).foregroundStyle(.secondary)
        }
    }
    private var addPhotos: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PhotosPicker(selection: $picked, maxSelectionCount: max(1, 5 - model.photos.count), selectionBehavior: .ordered, matching: .images) {
                    Label(importing ? "იტვირთება…" : "ფოტოების დამატება", systemImage: "photo.badge.plus")
                }.disabled(importing)
                if !isDemo && UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Spacer()
                    Button { camera = true } label: { Image(systemName: "camera") }.disabled(importing)
                }
            }.font(.kadri(15, weight: .semibold)).padding(14).background(.white, in: RoundedRectangle(cornerRadius: 14))
            Text("\(model.photos.count)/5 ფოტო · შემოწმების ფოტოსთვის ერთი ადგილი დატოვე.")
                .font(.kadri(12)).foregroundStyle(.secondary)
        }
    }
    private func stepCard(_ step: ProblemStep) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ნაბიჯი \(model.currentStepIndex + 1) / \(model.result?.steps.count ?? 0) · ფოტო \(number(step.photoId))")
                .font(.kadri(12, weight: .semibold)).foregroundStyle(Theme.Colors.brand[600]!)
            Text(step.title).font(.kadri(20, weight: .semibold))
            Text(step.text).font(.kadri(15)).fixedSize(horizontal: false, vertical: true)
            if selectedPhoto?.id != step.photoId {
                Button("ამ ნაბიჯის ფოტოზე დაბრუნება") { selectedID = step.photoId }.font(.kadri(14, weight: .semibold))
            }
            if let warning = step.warning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.kadri(14)) }
            if let tool = step.tool {
                HStack(spacing: 10) {
                    if let id = ToolCatalog.ids.first(where: { ToolCatalog.name($0) == tool }) {
                        PhotoToolSymbolView(toolID: id).frame(width: 44, height: 44)
                    } else { Image(systemName: "briefcase").accessibilityHidden(true) }
                    Text(tool).font(.kadri(14))
                }
            }
            TextField("შენიშვნა შედეგზე (არასავალდებულო)", text: $stepNote, axis: .vertical).font(.kadri(14))
                .onChange(of: stepNote) { _, value in stepNote = String(value.prefix(300)) }
            action("შევასრულე") { await model.markCurrentStep(outcome: .done, note: stepNote) }
            HStack {
                Button("ვერ ვასრულებ") { run { await model.markCurrentStep(outcome: .unable, note: stepNote) } }
                Spacer()
                Button("არაფერი შეიცვალა") { run { await model.markCurrentStep(outcome: .unchanged, note: stepNote) } }
            }.font(.kadri(13, weight: .medium))
        }.padding(18).background(.white, in: RoundedRectangle(cornerRadius: 20))
    }
    @ViewBuilder private func continuation(_ next: ProblemNext) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(next.kind == .resolved ? "მოგვარება დადასტურებულია" : next.prompt,
                  systemImage: next.kind == .resolved ? "checkmark.circle.fill" : "text.bubble")
                .font(.kadri(18, weight: .semibold))
            if !next.reason.isEmpty { Text(next.reason).font(.kadri(14)).foregroundStyle(.secondary) }
            if next.kind == .needsAnswer || next.kind == .verify {
                if next.kind == .verify && model.history.contains(where: { $0.outcome == .done }) {
                    action("კი, პრობლემა მოგვარდა") { await model.confirmResolution() }
                }
                TextField(next.kind == .verify ? "თუ არ მოგვარდა, აღწერე რა დარჩა" : "შენი პასუხი", text: $answer, axis: .vertical)
                    .font(.kadri(15)).padding(12).background(.white, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: answer) { _, value in answer = String(value.prefix(500)) }
                action("პასუხის გაგზავნა") {
                    let value = answer; answer = ""; await model.answer(value)
                }.disabled(answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importing)
            }

        }
    }
    private func evidenceSummary(_ result: ProblemResult) -> some View {
        DisclosureGroup("რა ჩანს და როგორ უკავშირდება") {
            VStack(alignment: .leading, spacing: 12) {
                Text(result.summary)
                ForEach(Array(model.answers.enumerated()), id: \.offset) { _, item in
                    Text(item.question + "\n" + item.answer)
                }
                ForEach(result.observations, id: \.photoId) { observation in
                    Text("ფოტო \(number(observation.photoId)): \(observation.detail)")
                }
                ForEach(Array(result.links.enumerated()), id: \.offset) { _, link in
                    Text("\(componentName(link.fromId)) ↔ \(componentName(link.toId)): \(link.reason)")
                }
            }.font(.kadri(14)).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.kadri(14, weight: .semibold))
    }
    private var history: some View {
        DisclosureGroup("შესრულების ისტორია · \(model.history.count)") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(model.history.enumerated()), id: \.offset) { _, item in
                    Text("\(item.outcome.georgianTitle) · \(item.title) · ფოტო \(number(item.photoId))" + (item.note.isEmpty ? "" : "\n" + item.note))
                }
            }.font(.kadri(13)).padding(.top, 10)
        }.font(.kadri(14))
    }
    private func action(_ title: String, perform: @escaping @MainActor () async -> Void) -> some View {
        Button(title) { run(perform) }.buttonStyle(SessionButtonStyle(primary: true)).disabled(model.isLoading || importing)
    }
    private func run(_ action: @escaping @MainActor () async -> Void) { operation = Task { await action() } }
    private func number(_ id: String) -> Int { (model.photos.firstIndex { $0.id == id } ?? 0) + 1 }
    private func componentName(_ id: String) -> String { model.result?.components.first { $0.id == id }?.name ?? "კომპონენტი" }
    private func append(_ data: Data) {
        let photo = ProblemPhoto(image: data, role: model.history.contains(where: { $0.outcome == .done }) ? .after : (model.photos.isEmpty ? .overview : .detail))
        if model.addPhoto(photo) { selectedID = photo.id } else { importError = "ამ სესიაში მაქსიმუმ 5 ფოტოს დამატება შეიძლება." }
    }
    private func importSelection() async {
        guard !picked.isEmpty else { return }
        importing = true; importError = nil
        defer { importing = false }
        for item in picked {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                let jpeg = try ProblemPhotoImport.jpeg(from: data)
                try Task.checkCancellation()
                append(jpeg)
            } catch is CancellationError { return }
            catch { importError = error.localizedDescription }
        }
        picked = []
    }
    private static func liveModel() -> ProblemSessionModel {
        let config = APIConfig.fromBundle() ?? APIConfig(baseURL: URL(string: "https://kadri-worker-staging.bekachkhirodze1.workers.dev")!)
        do {
            let storage = try DevAuth.storage()
            return ProblemSessionModel(api: KadriClient(config: config, auth: LiveAuth.store(config: config, storage: storage)))
        } catch { return ProblemSessionModel(api: ProblemUnavailableAPI(error: SessionError(error))) }
    }
}

struct ProblemEvidenceView: View {
    let photo: ProblemPhoto
    let result: ProblemResult?
    let step: ProblemStep?
    var parts: [Part] {
        (result?.components ?? []).compactMap { component in
            guard let view = component.views.first(where: { $0.photoId == photo.id }) else { return nil }
            return Part(id: component.id, name: component.name, box: view.box)
        }
    }
    var overlayStep: Step? {
        guard let step, step.photoId == photo.id else { return nil }
        return Step(index: 0, title: step.title, text: step.text, focus: step.componentIds,
                    markers: parts.filter { step.componentIds.contains($0.id) }.map { .init(part: $0.id, label: $0.name) },
                    arrows: step.arrow.map { arrow in step.componentIds.map { .init(part: $0, type: arrow.type, dir: arrow.dir) } } ?? [])
    }
    var body: some View {
        GeometryReader { proxy in
            if let image = UIImage(data: photo.image) {
                ZStack {
                    Color.white
                    Image(uiImage: image).resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                    PhotoAnnotationsView(step: overlayStep, parts: parts,
                        boxes: PhotoGeometry.boxes(parts: parts, viewport: proxy.size, imageSize: image.size), meshReady: [])
                }
            }
        }.accessibilityLabel("არჩეული ფოტო" + (overlayStep == nil ? "" : " · მოქმედება მონიშნულია"))
    }
}
private struct ProblemUnavailableAPI: KadriAPI {
    let error: SessionError
    func problem(_ request: ProblemRequest) async throws -> ProblemResult { throw error }
    func parts(keyframe: Data, instructions: String, context: SessionContext?) async throws -> PartsResult { throw error }
    func steps(object: String, parts: [Part], instructions: String, context: SessionContext?) -> AsyncThrowingStream<StepEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: error) }
    }
}
extension ProblemPhoto.Role {
    var georgianTitle: String {
        switch self { case .overview: "საერთო ხედი"; case .detail: "დეტალი"; case .label: "წარწერა"; case .after: "შედეგი" }
    }
}
extension ProblemHistory.Outcome {
    var georgianTitle: String {
        switch self { case .done: "შესრულდა"; case .unable: "ვერ შესრულდა"; case .unchanged: "არ შეიცვალა" }
    }
}
