#if DEBUG
import SwiftUI
import KadriCore

/// Offline lab using the same renderer as photo instructions. No AI requests.
struct PhotoArrowDemoView: View {
    @State private var scenario = 0
    @State private var kind = PhotoArrowKind.allCases[0]
    @State private var zoom: Double = 1
    @State private var paused = false

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        _kind = State(initialValue: value("--arrow-demo-kind").flatMap(PhotoArrowKind.init(rawValue:)) ?? .clockwise)
        _scenario = State(initialValue: min(2, max(0, Int(value("--arrow-demo-scene") ?? "0") ?? 0)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("მოძრაობის მინიშნებები").font(.kadri(24, weight: .semibold))
                Text("სატესტო ინსტრუქციები · ინტერნეტის გარეშე")
                    .font(.kadri(13)).foregroundStyle(.secondary)
                Picker("ფოტო", selection: $scenario) {
                    Text("ქანჩი").tag(0)
                    Text("საკეტი").tag(1)
                    Text("მილი").tag(2)
                }.pickerStyle(.segmented)
                PhotoArrowDemoScene(scenario: scenario, kind: kind,
                                    zoom: zoom, fixedPhase: paused ? 0.5 : nil)
                    .frame(height: 390).clipShape(RoundedRectangle(cornerRadius: 24))
                HStack {
                    Text("მოქმედება")
                    Spacer()
                    Picker("მოქმედება", selection: $kind) {
                        ForEach(PhotoArrowKind.allCases, id: \.rawValue) {
                            Text($0.title).tag($0)
                        }
                    }
                }
                HStack { Text("მასშტაბი"); Slider(value: $zoom, in: 0.65...1.4) }
                Toggle("მოძრაობის შეჩერება", isOn: $paused)
                Text("აირჩიე მოქმედება და შეცვალე მასშტაბი, რათა შეამოწმო, როგორ მიჰყვება ისარი დეტალს.")
                    .font(.kadri(12)).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Theme.Colors.surface).preferredColorScheme(.light)
    }
}

struct PhotoArrowDemoScene: View {
    let scenario: Int
    var kind: PhotoArrowKind = .allCases[0]
    var zoom: Double = 1
    var fixedPhase: CGFloat? = nil

    static func image(_ scenario: Int) -> UIImage? {
        let name = scenario == 1 ? "ArrowDemoRAM" : "PhotoDemo"
        let ext = scenario == 1 ? "jpg" : "png"
        return Bundle.main.url(forResource: name, withExtension: ext).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    private var part: Part {
        switch scenario {
        case 1: Part(id: "p1", name: "საკეტი", box: [462, 675, 545, 945])
        case 2: Part(id: "p1", name: "მილი", box: [308, 245, 650, 493])
        default: Part(id: "p1", name: "ქანჩი", box: [620, 250, 750, 385])
        }
    }

    var body: some View {
        GeometryReader { proxy in
            if let image = Self.image(scenario) {
                let original = PhotoGeometry.boxes(parts: [part], viewport: image.size, imageSize: image.size)
                let focus = PhotoGeometry.focusTransform(imageSize: image.size, viewport: proxy.size,
                    visibleRect: CGRect(origin: .zero, size: proxy.size), focusBoxes: Array(original.values))
                let mapping = CGAffineTransform(translationX: proxy.size.width / 2, y: proxy.size.height / 2)
                    .scaledBy(x: zoom, y: zoom)
                    .translatedBy(x: -proxy.size.width / 2, y: -proxy.size.height / 2)
                let transform = focus.concatenating(mapping)
                let boxes = PhotoGeometry.boxes(parts: [part], imageSize: image.size, transform: transform)
                let sourceBoxes = PhotoGeometry.boxes(parts: [part], viewport: proxy.size, imageSize: image.size)
                ZStack(alignment: .topLeading) {
                    Color(white: 0.93)
                    Image(uiImage: image).resizable()
                        .frame(width: image.size.width * transform.a, height: image.size.height * transform.d)
                        .position(x: transform.tx + image.size.width * transform.a / 2,
                                  y: transform.ty + image.size.height * transform.d / 2)
                    PhotoArrowOverlays(arrows: [kind.arrow], boxes: boxes,
                                       sizeBoxes: sourceBoxes, previewPhase: fixedPhase)
                    if let box = boxes["p1"] {
                        Text(part.name).font(.kadri(13, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: Capsule())
                            .position(x: min(proxy.size.width - 50, max(50, box.midX)), y: max(22, box.minY - 22))
                    }
                }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }
        }
    }
}
#endif
