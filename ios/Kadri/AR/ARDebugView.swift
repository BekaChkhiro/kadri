import SwiftUI
import RealityKit
import ARKit

struct ARDebugView: View {
    @StateObject private var controller = ARSessionController()
    @StateObject private var anchors = PartAnchors()
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if controller.supported {
                    ARCameraView(session: controller.session)
                    ForEach(anchors.unanchoredCenters(viewport: geometry.size), id: \.id) { item in
                        Text(item.id + " · 2D").font(.caption.bold()).padding(6)
                            .background(.orange).foregroundStyle(.black).position(item.point)
                    }
                    if let snapshot = controller.latest {
                        ForEach(anchors.projections(frame: snapshot.frame, viewport: geometry.size, scale: displayScale)) { projection in
                            Path { path in
                                guard let first = projection.corners.first else { return }
                                path.move(to: first)
                                projection.corners.dropFirst().forEach { path.addLine(to: $0) }
                                path.closeSubpath()
                            }.stroke(.green, lineWidth: 2)
                            ZStack {
                                Circle().stroke(.green, lineWidth: 3).frame(width: 16, height: 16)
                                VStack(spacing: 2) {
                                    Text(projection.id).font(.caption.bold())
                                    if let error = projection.returnErrorPixels {
                                        Text(String(format: "Δ %.1f px", error)).font(.caption.monospacedDigit())
                                    } else { Text("დაბრუნდით საწყის ხედზე").font(.caption2) }
                                }.padding(4).background(.black.opacity(0.5)).offset(y: 32)
                            }.foregroundStyle(.white).position(projection.center)
                        }
                    }
                }
                VStack(spacing: 12) {
                    Text(controller.status).font(.headline)
                    Text(controller.captureStatus).font(.caption)
                    if !anchors.unanchored.isEmpty {
                        Text("მიბმის გარეშე (2D): " + anchors.unanchored.joined(separator: ", ")).font(.caption)
                    }
                    Spacer()
                    Text("±30° მოაბრუნეთ და დაუბრუნდით საწყის ხედს. Δ ეკრანის ფიზიკურ პიქსელებშია; ეს დაბრუნების დიაგნოსტიკაა.")
                        .font(.caption)
                    HStack {
                        Button("კადრი") {
                            Task {
                                await controller.capture()
                            }
                        }.disabled(!controller.supported)
                        Button("სატესტო box-ები") {
                            guard let keyframe = controller.keyframe else { return }
                            anchors.place(keyframe: keyframe, parts: [
                                ("p1", [250, 350, 450, 600]),
                                ("p2", [550, 350, 750, 600])
                            ], session: controller.session)
                        }.disabled(controller.keyframe == nil)
                    }.buttonStyle(.borderedProminent)
                }.padding().foregroundStyle(.white)
            }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("AR დებაგი")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { controller.start() }
        .onDisappear { anchors.clear(session: controller.session); controller.pause() }
    }
}

private struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
