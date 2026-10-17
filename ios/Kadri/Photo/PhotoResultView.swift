import SwiftUI
import PhotosUI
import KadriCore

struct PhotoResultView: View {
    let image: UIImage
    let parts: [Part]
    let meshes: [TrackedMesh]
    let step: Step?
    let index: Int
    let count: Int
    let streaming: Bool
    let object: String
    let segmentationStatus: String?
    var close: () -> Void
    var previous: () -> Void
    var next: () -> Void
    var finish: () -> Void
    var completed = false
    var newPhoto: () -> Void = {}
    /// The round the shown step belongs to, out of every round so far.
    var round = 1
    var totalRounds = 1
    var continuation: StepsContinuation? = nil
    var continueCamera: () -> Void = {}
    var picked: Binding<PhotosPickerItem?>? = nil
    var continueDemo: (() -> Void)? = nil
    var cameraAvailable = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPhotoRequest = false

    private var photoRequest: (prompt: String, reason: String)? {
        if case .needsPhoto(let prompt, let reason) = continuation { return (prompt, reason) }
        return nil
    }

    var body: some View {
        PhotoScreenLayout(title: object, close: close, newPhoto: newPhoto) {
            GeometryReader { proxy in
                let sourceBoxes = PhotoGeometry.boxes(parts: parts, imageSize: image.size, transform: .identity)
                let transform = PhotoGeometry.focusTransform(imageSize: image.size, viewport: proxy.size,
                    visibleRect: CGRect(origin: .zero, size: proxy.size),
                    focusBoxes: completed ? [] : (step?.focus ?? []).compactMap { sourceBoxes[$0] })
                ZStack(alignment: .topLeading) {
                    Theme.Colors.ink[800]!
                    PhotoFocusedImageLayer(image: image, parts: parts, meshes: meshes, step: completed ? nil : step,
                        viewport: proxy.size, visibleHeight: proxy.size.height,
                        scale: transform.a, translationX: transform.tx, translationY: transform.ty)
                        .animation(reduceMotion ? nil : .spring(duration: 0.55), value: transform)
                    HStack(spacing: 6) {
                        PhotoChip(text: segmentationStatus ?? "\(parts.count) ნაწილი", symbol: "viewfinder")
                        if totalRounds > 1 { PhotoChip(text: "ფოტო \(round)", symbol: "photo.stack") }
                    }
                    .padding(12)
                }
            }
        } panel: {
            if completed {
                VStack(alignment: .leading, spacing: 16) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("დასრულდა").font(.kadri(21, weight: .semibold))
                            Text("ყველა ნაბიჯი დასრულებულია.").font(.kadri(14.5))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("ახალი ფოტო", action: newPhoto).buttonStyle(SessionButtonStyle())
                }.padding(16)
            } else if showingPhotoRequest, let photoRequest {
                PhotoRequestCard(round: totalRounds + 1, prompt: photoRequest.prompt, reason: photoRequest.reason,
                                 cameraAvailable: cameraAvailable, camera: continueCamera, picked: picked,
                                 demo: continueDemo, back: { showingPhotoRequest = false })
            } else {
                PhotoStepCard(step: step, index: index, count: count, streaming: streaming,
                              previous: previous, next: next, finish: finish,
                              needsPhoto: photoRequest != nil, requestPhoto: { showingPhotoRequest = true })
            }
        }
        .onChange(of: round) { showingPhotoRequest = false }
        .onChange(of: index) { showingPhotoRequest = false }
    }
}

/// Interpolate the mapping once, then derive every photo/mesh/annotation position from that frame.
/// Applying scaleEffect to the whole stack would also enlarge marker glyphs and line widths.
private struct PhotoFocusedImageLayer: View, Animatable {
    let image: UIImage
    let parts: [Part]
    let meshes: [TrackedMesh]
    let step: Step?
    let viewport: CGSize
    let visibleHeight: CGFloat
    nonisolated var scale: CGFloat
    nonisolated var translationX: CGFloat
    nonisolated var translationY: CGFloat

    nonisolated var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(scale, .init(translationX, translationY)) }
        set {
            scale = newValue.first
            translationX = newValue.second.first
            translationY = newValue.second.second
        }
    }

    var body: some View {
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: translationX, ty: translationY)
        let boxes = PhotoGeometry.boxes(parts: parts, imageSize: image.size, transform: transform)
        let baseBoxes = PhotoGeometry.boxes(parts: parts, viewport: viewport, imageSize: image.size)
        ZStack(alignment: .topLeading) {
            Image(uiImage: image).resizable()
                .frame(width: image.size.width * scale, height: image.size.height * scale)
                .position(x: translationX + image.size.width * scale / 2,
                          y: translationY + image.size.height * scale / 2)
            TrackedMeshOverlay(meshes: meshes, boxes: boxes, step: step)
                .environment(\.meshWrapFocusOutlineOnly, true)
            PhotoAnnotationsView(step: step, parts: parts, boxes: boxes,
                meshReady: Set(meshes.filter { $0.mesh.triangleCount > 0 }.map(\.id)),
                visibleHeight: visibleHeight, arrowSizeBoxes: baseBoxes)
        }
        .frame(width: viewport.width, height: viewport.height)
        .clipped().accessibilityHidden(true)
    }
}

#if DEBUG
private struct PhotoResultPreview: View {
    var waiting = false
    var showMeshes = false
    @State private var index = 0
    @State private var completed = false

    private var photo: UIImage {
        if let url = Bundle.main.url(forResource: "input", withExtension: "png", subdirectory: "sink"),
           let image = UIImage(contentsOfFile: url.path),
           let square = PhotoSession.squareJPEG(image, maxSide: 1536).flatMap(UIImage.init(data:)) { return square }
        return UIGraphicsImageRenderer(size: CGSize(width: 768, height: 768)).image { context in
            UIColor.systemGray3.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 768, height: 768))
        }
    }

    private var meshes: [TrackedMesh] {
        guard showMeshes else { return [] }
        return MockKadriAPI.result.parts.map { part in
            let b = part.box.map { CGFloat($0) / 1000 }
            let rect = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            let polygon = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                           CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
                .map { CGPoint(x: $0.x * 1024, y: $0.y * 1024) }
            return TrackedMesh(id: part.id, mesh: MeshTriangulation.triangulate(polygons: [polygon]), referenceBox: rect)
        }
    }

    var body: some View {
        PhotoResultView(image: photo, parts: MockKadriAPI.result.parts, meshes: meshes,
                        step: waiting ? nil : MockKadriAPI.sampleSteps[index], index: index,
                        count: waiting ? 0 : MockKadriAPI.sampleSteps.count, streaming: waiting,
                        object: MockKadriAPI.result.object, segmentationStatus: waiting ? "ვასკანერებ…" : nil,
                        close: { completed = true }, previous: { index = max(0, index - 1) },
                        next: { index = min(MockKadriAPI.sampleSteps.count - 1, index + 1) },
                        finish: { completed = true })
            .alert("სესია დასრულდა", isPresented: $completed) {
                Button("თავიდან") { index = 0 }
            }
    }
}

#Preview("ფოტო · ნაბიჯები") { PhotoResultPreview() }
#Preview("ფოტო · პირველი ნაბიჯის მოლოდინი") { PhotoResultPreview(waiting: true) }
#Preview("ფოტო · ბადეები") { PhotoResultPreview(showMeshes: true) }
#endif
