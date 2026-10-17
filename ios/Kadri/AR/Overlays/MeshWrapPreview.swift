import SwiftUI
import KadriCore

/// Uses the same bundled fixture as SegmentationBenchView; no model/API work in previews.
@MainActor
struct MeshWrapFixture {
    let photo: UIImage
    let meshes: [TriangulatedMesh]

    static func load(bundle: Bundle = .main) throws -> MeshWrapFixture {
        guard let directory = bundle.url(forResource: "sink", withExtension: nil),
              let photo = UIImage(contentsOfFile: directory.appendingPathComponent("input.png").path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let meshes = try (1...5).map { index in
            guard let image = UIImage(contentsOfFile: directory.appendingPathComponent("coreml_p\(index).png").path)?.cgImage else {
                throw CocoaError(.fileReadCorruptFile)
            }
            var pixels = [UInt8](repeating: 0, count: image.width*image.height)
            let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                              bitsPerComponent: 8, bytesPerRow: image.width,
                                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
                return true
            }
            guard drawn else { throw CocoaError(.fileReadCorruptFile) }
            return MeshTriangulation.triangulate(width: image.width, height: image.height, pixels: pixels)
        }
        return MeshWrapFixture(photo: photo, meshes: meshes)
    }
}

struct MeshWrapFixtureView: View {
    let fixture: MeshWrapFixture
    let state: MeshWrap.State
    var appeared = true
    var offset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / fixture.photo.size.width
            let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                              tx: offset.width, ty: offset.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: fixture.photo).resizable().scaledToFit()
                    .offset(offset)
                ForEach(fixture.meshes.indices, id: \.self) { i in
                    MeshWrap(mesh: fixture.meshes[i], transform: transform,
                             state: state == .idle ? .idle : (i == 3 || i == 4 ? state : .idle),
                             appeared: appeared)
                }
            }
            .modifier(SpotlightDim(meshes: state == .idle ? [] : Array(fixture.meshes.suffix(2)),
                                   transform: transform, active: state != .idle, appeared: appeared))
        }
        .aspectRatio(fixture.photo.size, contentMode: .fit)
        .clipped()
    }
}

struct MeshWrapPreview: View {
    @State var state: MeshWrap.State = .idle
    @State private var fixture: MeshWrapFixture?
    @State private var failure: String?
    @State private var appeared = true
    @State private var offset: CGSize = .zero

    var body: some View {
        VStack(spacing: 16) {
            if let fixture {
                MeshWrapFixtureView(fixture: fixture, state: state, appeared: appeared, offset: offset)
                    .gesture(DragGesture().onChanged { offset = $0.translation }.onEnded { _ in offset = .zero })
                Picker("მდგომარეობა", selection: $state) {
                    Text("ყველა").tag(MeshWrap.State.idle)
                    Text("ფოკუსი").tag(MeshWrap.State.focus)
                    Text("არ შეეხო").tag(MeshWrap.State.avoid)
                }.pickerStyle(.segmented)
                Toggle("ბადის გამოჩენა / სკანი", isOn: $appeared)
            } else if let failure {
                Text(failure)
            } else {
                ProgressView()
            }
        }
        .padding()
        .background(Theme.Colors.surface)
        .task {
            do { fixture = try MeshWrapFixture.load() }
            catch { failure = "sink fixture: \(error.localizedDescription)" }
        }
    }
}

#Preview("MeshWrap · idle") { MeshWrapPreview(state: .idle) }
#Preview("MeshWrap · focus") { MeshWrapPreview(state: .focus) }
#Preview("MeshWrap · avoid") { MeshWrapPreview(state: .avoid) }
#Preview("MeshWrap · reduced motion") {
    MeshWrapPreview(state: .focus).environment(\.meshWrapReduceMotion, true)
}
