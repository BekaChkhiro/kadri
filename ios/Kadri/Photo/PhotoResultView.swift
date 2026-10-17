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
    let title: String
    let subtitle: String
    let status: String?
    var close: () -> Void
    var previous: () -> Void
    var next: () -> Void
    var finish: () -> Void
    var completed = false
    var newPhoto: () -> Void = {}

    var body: some View {
        // Inset controls belong to a separate layer: they must never resize the photo coordinate space.
        Color.clear
            .background {
                GeometryReader { proxy in
                    let boxes = PhotoGeometry.boxes(parts: parts, viewport: proxy.size, imageSize: image.size)
                    ZStack(alignment: .top) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                            .accessibilityHidden(true)
                        TrackedMeshOverlay(meshes: meshes, boxes: boxes, step: step)
                            .accessibilityHidden(true)
                        PhotoAnnotationsView(step: step, parts: parts, boxes: boxes,
                                             meshReady: Set(meshes.filter { $0.mesh.triangleCount > 0 }.map(\.id)))
                        LinearGradient(colors: [.black.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: 150).allowsHitTesting(false)
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height).clipped()
                }
                .ignoresSafeArea()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                header.padding(.horizontal, 16).padding(.top, 8)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                ScrollView {
                    if completed {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("შესრულდა").font(.kadri(21, weight: .semibold))
                            Text("ყველა ნაბიჯი დასრულებულია.").font(.kadri(14.5))
                            Button("ახალი ფოტო", action: newPhoto).buttonStyle(SessionButtonStyle())
                        }.padding(16).glass().padding(.horizontal, 12).padding(.vertical, 8)
                    } else {
                        PhotoStepCard(step: step, index: index, count: count, streaming: streaming,
                                      caption: status ?? subtitle, previous: previous, next: next, finish: finish)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .fixedSize(horizontal: false, vertical: true)
            }
            .preferredColorScheme(.light)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44).glass(radius: 22)
            }
            .accessibilityLabel("დახურვა").accessibilityHint("დახურავს ფოტო სესიას")
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 14)).foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Theme.Colors.brand[500]!, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.kadri(14, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.kadri(12)).foregroundStyle(Theme.Colors.ink[500]!).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(6).padding(.trailing, 10).glass(radius: 28)
        }
        .foregroundStyle(Theme.Colors.ink[900]!)
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
                        title: "ნიჟარა ჟონავს", subtitle: "სიფონის შეკეთება · ~15 წთ", status: "ფოტოზე სიფონი ჩანს",
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
