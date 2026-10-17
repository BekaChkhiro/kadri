import SwiftUI
import RealityKit
import ARKit

struct ARBackgroundView: View {
    @ObservedObject var controller: ARSessionController
    var mockImage: UIImage?

    var body: some View {
        if controller.supported {
            FlowCameraView(session: controller.session)
        } else {
            GeometryReader { geometry in
                ZStack {
                    LinearGradient(colors: [.black, .gray], startPoint: .top, endPoint: .bottom)
                    if let mockImage {
                        Image(uiImage: mockImage).resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    }
                    Text("AR მიუწვდომელია").foregroundStyle(.white)
                        .padding(8).background(.black.opacity(0.6), in: Capsule())
                }
            }
        }
    }
}

private struct FlowCameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }
    func updateUIView(_ view: ARView, context: Context) {}
}
