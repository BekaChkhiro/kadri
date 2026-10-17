import SwiftUI
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var cardHeight: CGFloat = 0

    var body: some View {
        GeometryReader { screen in
            VStack(spacing: 0) {
                header.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
                GeometryReader { proxy in
                    let boxes = PhotoGeometry.boxes(parts: parts, viewport: proxy.size, imageSize: image.size)
                    ZStack(alignment: .topLeading) {
                        Theme.Colors.ink[800]!
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .accessibilityHidden(true)
                        TrackedMeshOverlay(meshes: meshes, boxes: boxes, step: step)
                            .accessibilityHidden(true)
                        PhotoAnnotationsView(step: step, parts: parts, boxes: boxes,
                                             meshReady: Set(meshes.filter { $0.mesh.triangleCount > 0 }.map(\.id)),
                                             visibleHeight: max(80, proxy.size.height - cardHeight - screen.safeAreaInsets.bottom - 16))
                        Label(segmentationStatus ?? "\(parts.count) ნაწილი", systemImage: "viewfinder")
                            .font(.kadri(12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background {
                                Capsule().fill(.ultraThinMaterial)
                                    .overlay(Capsule().fill(Theme.Colors.ink[900]!.opacity(0.55)))
                            }
                            .padding(12)
                    }
                    .overlay(alignment: .bottom) {
                        ScrollView {
                            if completed {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("დასრულდა").font(.kadri(21, weight: .semibold))
                                    Text("ყველა ნაბიჯი დასრულებულია.").font(.kadri(14.5))
                                    Button("ახალი ფოტო", action: newPhoto).buttonStyle(SessionButtonStyle())
                                }.padding(16).glass()
                            } else {
                                PhotoStepCard(step: step, index: index, count: count, streaming: streaming,
                                              caption: object, previous: previous, next: next, finish: finish)
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                        .padding(.horizontal, 12).padding(.bottom, screen.safeAreaInsets.bottom + 8)
                    }
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.card,
                                                     topTrailingRadius: Theme.Radius.card))
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .background(Theme.Colors.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel("დახურვა").accessibilityHint("დახურავს ფოტო სესიას")
            HStack(spacing: 8) {
                Circle().fill(Theme.Colors.brand[500]!).frame(width: 10, height: 10)
                    .overlay {
                        Circle().stroke(Theme.Colors.brand[400]!.opacity(pulse ? 0 : 0.6), lineWidth: 2)
                            .scaleEffect(pulse ? 1.8 : 1)
                            .animation(reduceMotion ? nil : .easeOut(duration: 1.5).repeatForever(autoreverses: false), value: pulse)
                    }
                    .accessibilityHidden(true)
                Text(object).font(.kadri(14, weight: .semibold)).lineLimit(1)
            }.frame(maxWidth: .infinity)
            Button(action: newPhoto) {
                Image(systemName: "photo.on.rectangle").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel("სხვა ფოტო").accessibilityHint("ახალი ფოტოს არჩევაზე გადავა")
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
        .onAppear { pulse = !reduceMotion }
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
           let image = UIImage(contentsOfFile: url.path) { return image }
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 768)).image { context in
            UIColor.systemGray3.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 512, height: 768))
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
