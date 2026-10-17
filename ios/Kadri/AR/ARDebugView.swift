import SwiftUI
import RealityKit
import ARKit
import os

/// Device-test log, readable from a Mac: idevicesyslog -p Kadri -m "ge.kadri"
private let arLog = Logger(subsystem: "ge.kadri", category: "ar")

struct ARDebugView: View {
    @StateObject private var controller = ARSessionController()
    @StateObject private var anchors = PartAnchors()
    @StateObject private var tracker = PartTracker()
    @StateObject private var displayRate = ContourDisplayRate()
    @StateObject private var touch = TouchSegmentation()
    @State private var touchMode = false
    @State private var showContours = false
    @State private var contourKeyframe: Keyframe?
    @Environment(\.displayScale) private var displayScale
    @State private var fps: Double = 0
    @State private var lastTimestamp: TimeInterval?
    @State private var lastHeartbeat: TimeInterval = 0
    @State private var lastAutoCapture: TimeInterval = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                if controller.supported {
                    ARCameraView(session: controller.session, delegate: controller)
                    ForEach(anchors.unanchoredCenters(viewport: geometry.size), id: \.id) { item in
                        Text(item.id + " · 2D").font(.caption.bold()).padding(6)
                            .background(.orange).foregroundStyle(.black).position(item.point)
                    }
                    if let snapshot = controller.latest {
                        if showContours || touchMode {
                            ContourOverlay(contours: tracker.contours,
                                           boxes: PartTracker.boxes(anchors.projections(frame: snapshot.frame, viewport: geometry.size, scale: displayScale))
                                            .merging(anchors.unanchoredBoxes(viewport: geometry.size), uniquingKeysWith: { first, _ in first }),
                                           focus: touchMode ? Set(tracker.contours.map(\.id)) : ["p1"], avoid: touchMode ? [] : ["p2"])
                                .allowsHitTesting(false)
                        }
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
                if touchMode {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { point in
                            touch.touch(point, viewport: geometry.size, controller: controller, anchors: anchors, tracker: tracker)
                        }
                }
                VStack(spacing: 12) {
                    if let snapshot = controller.latest {
                        ARStatusBar(frame: snapshot.frame, status: controller.status, fps: fps,
                                    anchored: anchors.projections(frame: snapshot.frame, viewport: geometry.size, scale: displayScale).count,
                                    unanchored: anchors.unanchored.count)
                    } else {
                        Text(controller.status).font(.headline)
                    }
                    Text(controller.captureStatus).font(.caption)
                    if !anchors.unanchored.isEmpty {
                        Text("მიბმის გარეშე (2D): " + anchors.unanchored.joined(separator: ", ")).font(.caption)
                    }
                    Toggle("შეხება", isOn: $touchMode)
                    if touchMode {
                        Text(touch.status).font(.caption)
                        Text(touch.timings).font(.caption.monospacedDigit())
                        Button("გასუფთავება") { touch.clear(controller: controller, anchors: anchors, tracker: tracker) }
                    }
                    Toggle("კონტურები", isOn: $showContours)
                        .disabled(touchMode || contourKeyframe == nil || anchors.placements.isEmpty)
                    if showContours {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "UI %.0f fps · embed %.1f ms · N %d", displayRate.fps, tracker.embedMs, tracker.interval))
                            ForEach(tracker.contours) { item in
                                Text(String(format: "%@ mask %.1f ms", item.id, item.maskMs))
                            }
                            if !tracker.status.isEmpty { Text(tracker.status) }
                        }.font(.caption.monospacedDigit())
                    }
                    Spacer()
                    Text("±30° მოაბრუნეთ და დაუბრუნდით საწყის ხედს. Δ ეკრანის ფიზიკურ პიქსელებშია; ეს დაბრუნების დიაგნოსტიკაა.")
                        .font(.caption)
                    HStack {
                        Button("კადრი") {
                            arLog.notice("ge.kadri tap capture")
                            Task {
                                await controller.capture()
                            }
                        }.disabled(!controller.supported || touchMode)
                        Button("სატესტო box-ები") {
                            guard let keyframe = controller.keyframe else { return }
                            arLog.notice("ge.kadri tap test-boxes")
                            placeTestBoxes(keyframe)
                        }.disabled(controller.keyframe == nil || touchMode)
                    }.buttonStyle(.borderedProminent)
                }.padding().foregroundStyle(.white)
            }
            .onChange(of: controller.latest?.timestamp) { _, _ in
                if let snapshot = controller.latest, showContours || touchMode { tracker.update(snapshot: snapshot, anchors: anchors) }
                if controller.latest == nil { touch.clear(controller: controller, anchors: anchors, tracker: tracker); tracker.stop(); showContours = false; contourKeyframe = nil }
            }
        }
        .onChange(of: touchMode) { _, _ in
            touch.clear(controller: controller, anchors: anchors, tracker: tracker)
            showContours = false; contourKeyframe = nil
        }
        .onChange(of: tracker.status) { _, status in arLog.notice("ge.kadri contour-status=\(status, privacy: .public)") }
        .onChange(of: tracker.contours.count) { _, count in arLog.notice("ge.kadri contours=\(count) embedMs=\(Int(tracker.embedMs))") }
        .onChange(of: showContours) { _, enabled in
            arLog.notice("ge.kadri show-contours=\(enabled) keyframe=\(contourKeyframe != nil) placements=\(anchors.placements.count)")
            if enabled, let keyframe = contourKeyframe {
                tracker.start(keyframe: keyframe, placements: anchors.placements)
            } else { tracker.stop() }
        }
        .preferredColorScheme(.dark)
        .navigationTitle("AR დებაგი")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: controller.latest?.frame.timestamp) { _, timestamp in
            guard let timestamp else { return }
            if let last = lastTimestamp, timestamp > last {
                fps = fps == 0 ? 1 / (timestamp - last) : fps * 0.9 + 0.1 / (timestamp - last)
            }
            lastTimestamp = timestamp
            autoCaptureIfReady(timestamp)
            if timestamp - lastHeartbeat >= 1, let frame = controller.latest?.frame {
                lastHeartbeat = timestamp
                let state: String
                switch frame.camera.trackingState {
                case .normal: state = "normal"
                case .notAvailable: state = "notAvailable"
                case .limited(let reason): state = "limited(\(reason))"
                }
                arLog.notice("ge.kadri hb tracking=\(state, privacy: .public) fps=\(Int(fps)) points=\(frame.rawFeaturePoints?.points.count ?? 0) depth=\(frame.sceneDepth != nil ? "lidar" : "raycast", privacy: .public) unanchored=\(anchors.unanchored.count) keyframe=\(controller.keyframe != nil)")
            }
        }
        .onChange(of: controller.status) { _, status in arLog.notice("ge.kadri status=\(status, privacy: .public)") }
        .onChange(of: controller.captureStatus) { _, status in arLog.notice("ge.kadri capture=\(status, privacy: .public)") }
        .onChange(of: controller.keyframe?.timestamp) { _, stamp in
            // First keyframe of the session: place test parts and show contours without any taps.
            guard stamp != nil, anchors.placements.isEmpty, let keyframe = controller.keyframe else { return }
            arLog.notice("ge.kadri auto test-boxes")
            placeTestBoxes(keyframe)
        }
        .onAppear { arLog.notice("ge.kadri ar-debug appear supported=\(controller.supported)"); controller.start(); displayRate.start() }
        .onDisappear { arLog.notice("ge.kadri ar-debug disappear"); touch.clear(controller: controller, anchors: anchors, tracker: tracker); tracker.stop(); showContours = false; contourKeyframe = nil; displayRate.stop(); anchors.clear(session: controller.session); controller.pause() }
    }

    private func placeTestBoxes(_ keyframe: Keyframe) {
        anchors.place(keyframe: keyframe, parts: [
            ("p1", [250, 350, 450, 600]),
            ("p2", [550, 350, 750, 600])
        ], session: controller.session)
        contourKeyframe = keyframe
        // Contours turn on automatically once parts are placed; the toggle can still hide them.
        if showContours { tracker.start(keyframe: keyframe, placements: anchors.placements) } else { showContours = true }
        arLog.notice("ge.kadri placed unanchored=\(anchors.unanchored.joined(separator: ","), privacy: .public)")
    }

    /// Until the first keyframe exists, try a capture every 0.8 s while tracking is normal.
    private func autoCaptureIfReady(_ timestamp: TimeInterval) {
        guard controller.keyframe == nil, timestamp - lastAutoCapture >= 0.8,
              case .normal = controller.latest?.frame.camera.trackingState else { return }
        lastAutoCapture = timestamp
        Task { await controller.capture() }
    }
}

/// Live proof the session is really looking: tracking state, camera rate, feature points, depth source, anchors, light.
private struct ARStatusBar: View {
    let frame: ARFrame
    let status: String
    let fps: Double
    let anchored: Int
    let unanchored: Int

    private var color: Color {
        switch frame.camera.trackingState {
        case .normal: return .green
        case .limited: return .orange
        case .notAvailable: return .red
        }
    }

    var body: some View {
        let points = frame.rawFeaturePoints?.points.count ?? 0
        let depth = frame.sceneDepth != nil ? "LiDAR" : "raycast"
        let lux = frame.lightEstimate.map { Int($0.ambientIntensity) }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(color).frame(width: 10, height: 10)
                Text(status).font(.subheadline.bold())
            }
            HStack(spacing: 12) {
                Label(String(format: "%.0f fps", fps), systemImage: "camera")
                Label("\(points)", systemImage: "circle.grid.cross")
                Label(depth, systemImage: "cube.transparent")
                Label("\(anchored)/\(anchored + unanchored)", systemImage: "mappin.and.ellipse")
                if let lux { Label("\(lux)", systemImage: "sun.max") }
            }
            .font(.caption.monospacedDigit())
            .labelStyle(.titleAndIcon)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}

private struct ARCameraView: UIViewRepresentable {
    let session: ARSession
    let delegate: ARSessionDelegate
    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.session = session
        // ARView takes over session.delegate; ARSessionController polls currentFrame instead.
        return view
    }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
