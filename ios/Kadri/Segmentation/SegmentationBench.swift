import CoreGraphics
import CoreML
import Foundation
import UIKit

/// Phone benchmark for the SAM models; the JSON is meant to be pasted back into chat.
struct SegmentationBenchReport: Codable, Sendable {
    struct Stats: Codable, Sendable {
        let median: Double
        let min: Double
        let max: Double

        init(_ samples: [Double]) {
            let sorted = samples.sorted()
            median = sorted.isEmpty ? 0 : (sorted.count % 2 == 1
                ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2)
            min = sorted.first ?? 0
            max = sorted.last ?? 0
        }
    }

    struct Part: Codable, Sendable {
        let id: String
        let box: [Int]
        let decoderColdMs: Double
        let decoderWarmMs: Stats
        let postWarmMs: Stats
        let score: Float
        let selected: Int
        let maskPixels: Int
    }

    let device: String
    let system: String
    let computeUnits: String
    let image: String
    let width: Int
    let height: Int
    let runs: Int
    let loadMs: Double
    let preColdMs: Double
    let encoderColdMs: Double
    let preWarmMs: Stats
    let encoderWarmMs: Stats
    let parts: [Part]
    let date: String

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: (try? encoder.encode(self)) ?? Data(), as: UTF8.self)
    }
}

struct BenchPart: Sendable {
    let id: String
    let box: PartBox
}

enum SegmentationBench {
    static func run(image: CGImage, imageName: String, parts: [BenchPart], computeUnits: MLComputeUnits,
                    runs: Int = 10) async throws -> (SegmentationBenchReport, [Mask]) {
        let segmenter = try Segmenter(computeUnits: computeUnits)
        // Cold: first prediction after load (ANE/GPU compilation lands here or in load).
        let cold = try await segmenter.embed(image)
        var pre: [Double] = [], encode: [Double] = []
        var embedding = cold
        for _ in 0..<runs {
            embedding = try await segmenter.embed(image)
            pre.append(embedding.preMs)
            encode.append(embedding.encodeMs)
        }
        var rows: [SegmentationBenchReport.Part] = []
        var masks: [Mask] = []
        for part in parts {
            let first = try await segmenter.mask(embedding: embedding, box: part.box)
            var decode: [Double] = [], post: [Double] = []
            var last = first
            for _ in 0..<runs {
                last = try await segmenter.mask(embedding: embedding, box: part.box)
                decode.append(last.decodeMs)
                post.append(last.postMs)
            }
            masks.append(last)
            rows.append(.init(id: part.id, box: part.box.values, decoderColdMs: first.decodeMs,
                              decoderWarmMs: .init(decode), postWarmMs: .init(post), score: last.score,
                              selected: last.selected, maskPixels: last.area))
        }
        let report = SegmentationBenchReport(
            device: deviceModel(), system: await UIDevice.current.systemVersion,
            computeUnits: name(computeUnits), image: imageName, width: image.width, height: image.height,
            runs: runs, loadMs: segmenter.loadMs, preColdMs: cold.preMs, encoderColdMs: cold.encodeMs,
            preWarmMs: .init(pre), encoderWarmMs: .init(encode), parts: rows,
            date: ISO8601DateFormatter().string(from: Date()))
        return (report, masks)
    }

    static func name(_ units: MLComputeUnits) -> String {
        switch units {
        case .all: "ALL"
        case .cpuAndNeuralEngine: "CPU_AND_NE"
        case .cpuOnly: "CPU_ONLY"
        case .cpuAndGPU: "CPU_AND_GPU"
        @unknown default: "UNKNOWN"
        }
    }

    /// e.g. "iPhone13,2" (iPhone 12) or "iPhone16,1" (15 Pro); simulators report the host arch.
    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
