import CoreML
import PhotosUI
import SwiftUI

/// Developer screen: times SAM on the phone and shows the masks over the frame.
struct SegmentationBenchView: View {
    private struct Frame {
        let image: CGImage
        let name: String
        let parts: [BenchPart]
    }

    private struct FixtureFile: Decodable {
        struct Part: Decodable {
            let id: String
            let box: [Int]
        }
        let parts: [Part]
    }

    @State private var units = "ALL"
    @State private var frame: Frame?
    @State private var pick: PhotosPickerItem?
    @State private var report: SegmentationBenchReport?
    @State private var overlay: CGImage?
    @State private var running = false
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        List {
            Section {
                Picker("Compute units", selection: $units) {
                    Text("ALL").tag("ALL")
                    Text("CPU_AND_NE").tag("CPU_AND_NE")
                }
                .pickerStyle(.segmented)
                Button("ჩაშენებული sink კადრი") { loadFixture() }
                PhotosPicker("ფოტოს არჩევა (ცენტრალური box)", selection: $pick, matching: .images)
                Button(running ? "მიმდინარეობს…" : "გაშვება (10×)") { run() }
                    .disabled(running || frame == nil)
            } footer: {
                Text("ცივი = პირველი გაშვება მოდელის ჩატვირთვის შემდეგ; თბილი = შემდეგი 10-ის მედიანა.")
            }

            if let frame {
                Section(frame.name) {
                    Image(decorative: frame.image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .overlay {
                            if let overlay {
                                Image(decorative: overlay, scale: 1).resizable().scaledToFit()
                            }
                        }
                }
            }

            if let message {
                Section { Text(message).foregroundStyle(.red) }
            }

            if let report {
                Section("\(report.device) · \(report.computeUnits) · \(report.width)×\(report.height)") {
                    row("მოდელების ჩატვირთვა", report.loadMs)
                    row("pre ცივი / თბილი", report.preColdMs, report.preWarmMs.median)
                    row("encoder ცივი / თბილი", report.encoderColdMs, report.encoderWarmMs.median)
                    ForEach(report.parts, id: \.id) { part in
                        row("\(part.id) decoder ცივი / თბილი", part.decoderColdMs, part.decoderWarmMs.median)
                        row("\(part.id) post თბილი · score \(String(format: "%.2f", part.score))",
                            part.postWarmMs.median)
                    }
                    Button(copied ? "დაკოპირდა ✓" : "კოპირება (JSON)") {
                        UIPasteboard.general.string = report.json
                        copied = true
                    }
                }
            }
        }
        .navigationTitle("SAM bench")
        .task { if frame == nil { loadFixture() } }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
    }

    private func row(_ title: String, _ values: Double...) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(values.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " მს")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func loadFixture() {
        do {
            guard let dir = Bundle.main.url(forResource: "sink", withExtension: nil) else {
                throw SegmentationError.imageDecodeFailed
            }
            let image = try SegmentationImage.load(dir.appendingPathComponent("input.png"))
            let file = try JSONDecoder().decode(FixtureFile.self,
                                                from: Data(contentsOf: dir.appendingPathComponent("boxes.json")))
            let parts = try file.parts.map { BenchPart(id: $0.id, box: try PartBox($0.box)) }
            setFrame(Frame(image: image, name: "sink fixture", parts: parts))
        } catch {
            message = error.localizedDescription
        }
    }

    private func loadPicked(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self), let photo = UIImage(data: data) else {
                throw SegmentationError.imageDecodeFailed
            }
            // Bake orientation in and cap the long side near a camera frame's size.
            let scale = min(1, 1440 / max(photo.size.width, photo.size.height))
            let size = CGSize(width: (photo.size.width * scale).rounded(), height: (photo.size.height * scale).rounded())
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                photo.draw(in: CGRect(origin: .zero, size: size))
            }
            guard let image = rendered.cgImage else { throw SegmentationError.imageDecodeFailed }
            setFrame(Frame(image: image, name: "ფოტო \(image.width)×\(image.height)",
                           parts: [BenchPart(id: "center", box: PartBox(x0: 300, y0: 300, x1: 700, y1: 700))]))
        } catch {
            message = error.localizedDescription
        }
    }

    private func setFrame(_ new: Frame) {
        frame = new
        overlay = nil
        report = nil
        message = nil
    }

    private func run() {
        guard let frame else { return }
        let computeUnits: MLComputeUnits = units == "ALL" ? .all : .cpuAndNeuralEngine
        let image = frame.image, name = frame.name, parts = frame.parts
        running = true
        message = nil
        copied = false
        Task {
            do {
                let (result, masks) = try await Task.detached(priority: .userInitiated) {
                    try await SegmentationBench.run(image: image, imageName: name, parts: parts,
                                                    computeUnits: computeUnits)
                }.value
                report = result
                overlay = SegmentationImage.overlay(masks)
            } catch {
                message = error.localizedDescription
            }
            running = false
        }
    }
}

#Preview {
    NavigationStack { SegmentationBenchView() }
}
