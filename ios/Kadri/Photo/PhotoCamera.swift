import AVFoundation
import SwiftUI
import UIKit

struct PhotoCamera: View {
    var selected: (UIImage) -> Void
    @StateObject private var camera: PhotoCaptureCamera

    private let fullFrame: Bool

    /// fullFrame keeps the whole sensor frame (explain: wide dashboards lose edge lights in a square crop).
    init(camera: PhotoCaptureCamera? = nil, fullFrame: Bool = false, selected: @escaping (UIImage) -> Void) {
        let camera = camera ?? PhotoCaptureCamera(fullFrame: fullFrame)
        _camera = StateObject(wrappedValue: camera)
        self.fullFrame = camera.fullFrame
        self.selected = selected
    }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var blink = false

    var body: some View {
        GeometryReader { geometry in
            let size = viewfinderSize(width: geometry.size.width - 24, height: geometry.size.height - 156)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                viewfinder
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
                    .shadow(Theme.Shadow.card)
                Spacer(minLength: 0)
                controls.padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Colors.surface.ignoresSafeArea())
        .preferredColorScheme(.light)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else { camera.stop() }
        }
        .task(id: camera.image) {
            guard camera.image != nil else { return }
            blink = true
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { blink = false }
        }
    }

    /// Square for the photo session; the portrait 3:4 photo frame when fullFrame.
    private func viewfinderSize(width: CGFloat, height: CGFloat) -> CGSize {
        guard fullFrame else { let side = min(width, height); return CGSize(width: side, height: side) }
        let fitted = min(width, height * 3 / 4)
        return CGSize(width: fitted, height: fitted * 4 / 3)
    }

    private var viewfinder: some View {
        ZStack {
            Theme.Colors.ink[200]!
            if let message = camera.message {
                VStack(spacing: 16) {
                    Text(message).font(.kadri(16)).multilineTextAlignment(.center)
                    if camera.permissionDenied {
                        Button("პარამეტრების გახსნა") {
                            if let url = URL(string: UIApplication.openSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }.buttonStyle(SessionButtonStyle())
                    }
                }.foregroundStyle(Theme.Colors.ink[800]!).padding(24)
            } else if let image = camera.image ?? camera.demoImage {
                if fullFrame {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            } else {
                PhotoCapturePreview(session: camera.session, gravity: fullFrame ? .resizeAspect : .resizeAspectFill)
            }
            Color.white.opacity(blink ? (reduceMotion ? 0.4 : 0.9) : 0)
                .allowsHitTesting(false)
        }
        .accessibilityIdentifier("photo-capture-viewfinder")
    }

    private var controls: some View {
        HStack(spacing: 24) {
            Button { camera.stop(); dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 26, weight: .regular))
                    .foregroundStyle(Theme.Colors.ink[800]!)
                    .frame(width: 56, height: 56)
                    .background(.ultraThinMaterial, in: Circle())
                    .background(Color.white.opacity(0.75), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.6), lineWidth: 1))
                    .shadow(Theme.Shadow.card)
            }
            .buttonStyle(PhotoCapturePressStyle(scale: 0.94))
            .accessibilityLabel("დახურვა")
            .frame(maxWidth: .infinity, alignment: .trailing)

            Button { camera.capture() } label: {
                Circle().fill(.white).frame(width: 78, height: 78)
                    .overlay(Circle().fill(Theme.Colors.brand[500]!).frame(width: 62, height: 62))
                    .shadow(Theme.Shadow.pop)
            }
            .buttonStyle(PhotoCapturePressStyle(scale: 0.92))
            .disabled(!camera.ready || camera.capturing)
            .accessibilityLabel("გადაღება")

            ZStack {
                if let image = camera.image {
                    Button { camera.stop(); selected(image); dismiss() } label: {
                        Image(systemName: "checkmark").font(.system(size: 26, weight: .regular))
                            .foregroundStyle(.white).frame(width: 56, height: 56)
                            .background(Theme.Colors.brand[500]!, in: Circle())
                            .shadow(Theme.Shadow.pop)
                    }
                    .buttonStyle(PhotoCapturePressStyle(scale: 0.94))
                    .accessibilityLabel("გაგზავნა")
                    .disabled(camera.capturing)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .frame(width: 56, height: 56)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.3, dampingFraction: 0.7), value: camera.image != nil)
    }
}

private struct PhotoCapturePressStyle: ButtonStyle {
    let scale: CGFloat
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct PhotoCapturePreview: UIViewRepresentable {
    let session: AVCaptureSession
    let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> Preview {
        let view = Preview()
        view.preview.session = session
        view.preview.videoGravity = gravity
        return view
    }
    func updateUIView(_ view: Preview, context: Context) {
        view.setNeedsLayout()
    }

    final class Preview: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        override func layoutSubviews() {
            super.layoutSubviews()
            // Kadri is portrait-only; match the photo output's rotation.
            if let connection = preview.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}

/// Session and output are confined to queue; observable UI state is published on main.
final class PhotoCaptureCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let fullFrame: Bool
    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "ge.kadri.photo-capture")
    private var wantsRunning = false
    private var configured = false
    @Published private(set) var image: UIImage?
    @Published private(set) var ready = false
    @Published private(set) var capturing = false
    @Published private(set) var message: String?
    @Published private(set) var permissionDenied = false

    init(fullFrame: Bool = false) {
        self.fullFrame = fullFrame
        super.init()
    }

    var demoImage: UIImage? {
        #if DEBUG && targetEnvironment(simulator)
        guard let url = Bundle.main.url(forResource: "PhotoDemo", withExtension: "png"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return Self.prepared(image, fullFrame: fullFrame)
        #else
        return nil
        #endif
    }

    func start() {
        #if DEBUG && targetEnvironment(simulator)
        ready = demoImage != nil
        return
        #else
        queue.async {
            self.wantsRunning = true
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: self.configureAndStart()
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.queue.async {
                        guard self.wantsRunning else { return }
                        if granted { self.configureAndStart() } else { self.denied() }
                    }
                }
            default: self.denied()
            }
        }
        #endif
    }

    func stop() {
        #if DEBUG && targetEnvironment(simulator)
        ready = false
        #else
        queue.async {
            self.wantsRunning = false
            if self.session.isRunning { self.session.stopRunning() }
            DispatchQueue.main.async { self.ready = false }
        }
        #endif
    }

    private func denied() {
        DispatchQueue.main.async {
            self.ready = false
            self.permissionDenied = true
            self.message = "კამერაზე წვდომა გამორთულია. ჩართე კამერა პარამეტრებში."
        }
    }

    private func configureAndStart() {
        guard wantsRunning else { return }
        if !configured {
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else {
                fail("კამერა მიუწვდომელია."); return
            }
            session.beginConfiguration()
            session.sessionPreset = .photo
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                fail("კამერის ჩართვა ვერ მოხერხდა."); return
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            configured = true
        }
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async {
            self.permissionDenied = false
            self.message = nil
            self.ready = true
        }
    }

    func capture() {
        guard ready, !capturing else { return }
        capturing = true
        #if DEBUG && targetEnvironment(simulator)
        image = demoImage
        capturing = false
        #else
        queue.async {
            guard self.session.isRunning else {
                self.fail("კამერა შეჩერებულია. სცადე ხელახლა."); return
            }
            if let connection = self.output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        }
        #endif
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation(), let original = UIImage(data: data) else {
            fail("ფოტოს გადაღება ვერ მოხერხდა. სცადე ხელახლა."); return
        }
        let prepared = Self.prepared(original, fullFrame: fullFrame)
        DispatchQueue.main.async {
            self.image = prepared
            self.message = nil
            self.capturing = false
        }
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.message = message; self.capturing = false }
    }

    /// Square crop for the photo session; fullFrame only bakes the EXIF orientation in, keeping the aspect.
    static func prepared(_ image: UIImage, fullFrame: Bool) -> UIImage {
        guard fullFrame else { return square(image) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    /// UIImage.draw applies EXIF orientation before the central crop, matching aspect-fill preview.
    static func square(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(x: (side - image.size.width) / 2, y: (side - image.size.height) / 2,
                                  width: image.size.width, height: image.size.height))
        }
    }
}
