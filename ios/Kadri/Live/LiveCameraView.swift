import SwiftUI
import KadriCore

struct LiveCameraView: View {
    @StateObject private var session = LiveCameraSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        LiveCameraContent(session: session, controller: session.controller, tracker: session.tracker,
                          close: { dismiss() })
    }
}

private struct LiveCameraContent: View {
    @ObservedObject var session: LiveCameraSession
    @ObservedObject var controller: ARSessionController
    @ObservedObject var tracker: PartTracker
    let close: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    private let heartbeat = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("ცოცხალი კამერა (ტესტი)").font(.kadri(18, weight: .semibold))
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("დახურვა")
            }.padding(.horizontal, 16)
            if controller.supported && !session.permissionDenied {
                camera
                controls.frame(maxHeight: 330)
                    .background(Theme.Colors.surface)
            } else {
                Spacer()
                Image(systemName: "camera.fill").font(.system(size: 36))
                    .foregroundStyle(Theme.Colors.brand[500]!)
                Text(session.status(visibleCount: 0).text)
                    .font(.kadri(20, weight: .semibold)).multilineTextAlignment(.center).padding(24)
                if session.permissionDenied {
                    Button("პარამეტრები") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }.buttonStyle(SessionButtonStyle()).padding(.horizontal, 24)
                }
                Spacer()
                Button("დახურვა", action: close)
                    .buttonStyle(SessionButtonStyle()).padding(20)
            }
        }
        .background(Theme.Colors.surface)
        .foregroundStyle(Theme.Colors.ink[900]!)
        .preferredColorScheme(.light)
        .task { await session.start() }
        .onDisappear { session.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await session.start() } }
            else { session.stop() }
        }
        .onChange(of: controller.latest?.timestamp) { _, _ in session.update() }
        .onReceive(heartbeat) { _ in session.update() }
        .onChange(of: session.model.phase) { _, _ in session.phaseChanged() }
    }

    private var camera: some View {
        GeometryReader { proxy in
            let projections = session.projections(viewport: proxy.size, scale: displayScale)
            let boxes = PartTracker.boxes(projections)
            ZStack {
                ARBackgroundView(controller: controller)
                ContourOverlay(contours: tracker.contours, boxes: boxes,
                               focus: Set([session.selectedID].compactMap { $0 }))
                    .allowsHitTesting(false)
                ForEach(projections) { projection in
                    if let part = session.model.partsResult?.parts.first(where: { $0.id == projection.id }) {
                        Button { session.selectedID = part.id } label: {
                            VStack(spacing: 4) {
                                Circle().fill(Theme.Colors.brand[500]!).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                                Text(part.name).font(.kadri(12, weight: .semibold))
                                    .lineLimit(2).multilineTextAlignment(.center)
                                    .padding(.horizontal, 10).padding(.vertical, 7)
                                    .background(.regularMaterial, in: Capsule())
                            }.frame(maxWidth: 150)
                        }.buttonStyle(.plain)
                            .accessibilityLabel(part.name)
                            .accessibilityAddTraits(session.selectedID == part.id ? .isSelected : [])
                            .position(projection.center)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .top) {
                Text(session.status(visibleCount: projections.count).text)
                    .font(.kadri(14, weight: .medium)).multilineTextAlignment(.center)
                    .padding(12).background(.regularMaterial, in: Capsule()).padding(12)
                    .allowsHitTesting(false)
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let result = session.model.partsResult {
                Text(result.object).font(.kadri(18, weight: .semibold))
                Text("შეეხე ნაწილს მის მოსანიშნად.").font(.kadri(14))
                if !tracker.status.isEmpty {
                    Text(tracker.status == "კონტურების განახლება…" ? "კონტურები მზადდება…" : "კონტური მიუწვდომელია")
                        .font(.kadri(12)).foregroundStyle(Theme.Colors.ink[500]!)
                }
            } else {
                Text("მიუშვირე კამერა უძრავ ობიექტს და დაიჭირე სტაბილურად.")
                    .font(.kadri(15))
            }
            if case .error(.unauthorized, _) = session.model.phase {
                PhotoAuthActions(retry: session.recognizeAgain)
            } else {
                Button("ხელახლა ამოცნობა", action: session.recognizeAgain)
                    .buttonStyle(SessionButtonStyle(primary: false))
            }
        }.padding(16)
    }
}
