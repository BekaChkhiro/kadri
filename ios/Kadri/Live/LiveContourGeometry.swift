import Foundation
import simd
import KadriCore

/// Unit square to the four ordered AR-projected corners (TL, TR, BR, BL).
/// Unlike an axis-aligned bounding box this preserves rotation and perspective.
struct LiveContourWarp: Sendable {
    let matrix: simd_double3x3

    init?(quad: [CGPoint]) {
        guard quad.count == 4, quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let p = quad.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let cross = (0..<4).map { i -> Double in
            let a = p[(i+1)%4] - p[i], b = p[(i+2)%4] - p[(i+1)%4]
            return a.x*b.y - a.y*b.x
        }
        guard cross.allSatisfy({ $0 > 1e-10 }) || cross.allSatisfy({ $0 < -1e-10 }) else { return nil }
        let d1 = p[1] - p[2], d2 = p[3] - p[2], d3 = p[0] - p[1] + p[2] - p[3]
        let det = d1.x*d2.y - d2.x*d1.y
        guard abs(det) > 1e-12 else { return nil }
        let g = (d3.x*d2.y - d2.x*d3.y)/det
        let h = (d1.x*d3.y - d3.x*d1.y)/det
        matrix = simd_double3x3(columns: (
            SIMD3(p[1].x-p[0].x+g*p[1].x, p[1].y-p[0].y+g*p[1].y, g),
            SIMD3(p[3].x-p[0].x+h*p[3].x, p[3].y-p[0].y+h*p[3].y, h),
            SIMD3(p[0].x, p[0].y, 1)))
        guard abs(matrix.determinant) > 1e-12 else { return nil }
    }

    static func corners(_ box: CGRect) -> [CGPoint] {
        [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
         CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
    }

    func apply(_ point: CGPoint, inverse: Bool = false) -> CGPoint? {
        let p = (inverse ? matrix.inverse : matrix) * SIMD3(Double(point.x), Double(point.y), 1)
        guard p.x.isFinite, p.y.isFinite, p.z.isFinite, p.z > 1e-8 else { return nil }
        return CGPoint(x: p.x/p.z, y: p.y/p.z)
    }

    func polygons(_ polygons: [[CGPoint]], inverse: Bool = false) -> [[CGPoint]]? {
        var result: [[CGPoint]] = []
        for polygon in polygons {
            let mapped = polygon.compactMap { apply($0, inverse: inverse) }
            guard mapped.count == polygon.count, mapped.count >= 3 else { return nil }
            result.append(mapped)
        }
        return result.isEmpty ? nil : result
    }
}

enum LiveContourGeometry {
    /// Raster IoU in the captured portrait image, not in two different camera poses.
    /// Bounded work is done on the inference actor, never on the display path.
    static func iou(_ a: [[CGPoint]], _ b: [[CGPoint]], resolution: Int = 128) -> Double {
        guard resolution > 0, !a.isEmpty, !b.isEmpty else { return 0 }
        let bounds = ContourGeometry.bounds(a.flatMap { $0 } + b.flatMap { $0 })
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else { return 0 }
        var intersection = 0, union = 0
        for y in 0..<resolution { for x in 0..<resolution {
            let point = CGPoint(x: bounds.minX + (CGFloat(x)+0.5)*bounds.width/CGFloat(resolution),
                                y: bounds.minY + (CGFloat(y)+0.5)*bounds.height/CGFloat(resolution))
            let inA = contains(point, polygons: a), inB = contains(point, polygons: b)
            if inA || inB { union += 1 }
            if inA && inB { intersection += 1 }
        }}
        return union == 0 ? 0 : Double(intersection)/Double(union)
    }

    private static func contains(_ point: CGPoint, polygons: [[CGPoint]]) -> Bool {
        polygons.contains { polygon in
            guard polygon.count >= 3 else { return false }
            var inside = false
            for i in polygon.indices {
                let a = polygon[i], b = polygon[(i+1)%polygon.count]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x-a.x)*(point.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
            }
            return inside
        }
    }

    static func resample(_ polygon: [CGPoint], count: Int = 64) -> [CGPoint] {
        guard polygon.count >= 3, count >= 3 else { return [] }
        let lengths = polygon.indices.map { i in
            hypot(polygon[(i+1)%polygon.count].x-polygon[i].x, polygon[(i+1)%polygon.count].y-polygon[i].y)
        }
        let perimeter = lengths.reduce(0, +)
        guard perimeter.isFinite, perimeter > 1e-8 else { return [] }
        var edge = 0, start: CGFloat = 0
        return (0..<count).map { i in
            let distance = CGFloat(i)*perimeter/CGFloat(count)
            while edge < lengths.count-1 && start+lengths[edge] < distance { start += lengths[edge]; edge += 1 }
            let t = (distance-start)/max(lengths[edge], 1e-12)
            let a = polygon[edge], b = polygon[(edge+1)%polygon.count]
            return CGPoint(x: a.x+(b.x-a.x)*t, y: a.y+(b.y-a.y)*t)
        }
    }

    /// Smooth only the shape in its anchored plane. Camera pose stays immediate,
    /// so filtering does not leave a trailing contour while the phone moves.
    static func smooth(old: [[CGPoint]], new: [[CGPoint]], alpha: CGFloat = 0.2) -> [[CGPoint]]? {
        guard old.count == new.count, !old.isEmpty, (0...1).contains(alpha) else { return nil }
        var result: [[CGPoint]] = []
        for (a, polygon) in zip(old, new) {
            guard a.count >= 3 else { return nil }
            let b = resample(polygon, count: a.count)
            guard b.count == a.count else { return nil }
            var best = b, error = CGFloat.infinity
            // Vision can change winding or the starting vertex between masks.
            for ring in [b, Array(b.reversed())] {
                for shift in ring.indices {
                    let aligned = a.indices.map { ring[($0+shift)%ring.count] }
                    let cost = zip(a, aligned).reduce(CGFloat.zero) { sum, pair in
                        let dx = pair.0.x-pair.1.x, dy = pair.0.y-pair.1.y
                        return sum + dx*dx + dy*dy
                    }
                    if cost < error { best = aligned; error = cost }
                }
            }
            result.append(zip(a, best).map { CGPoint(x: $0.x+($1.x-$0.x)*alpha, y: $0.y+($1.y-$0.y)*alpha) })
        }
        return result
    }

    static func accept(previous: [[CGPoint]], candidate: [[CGPoint]], captureWarp: LiveContourWarp) -> [[CGPoint]]? {
        guard let predicted = captureWarp.polygons(previous), iou(predicted, candidate) >= 0.6,
              let canonical = captureWarp.polygons(candidate, inverse: true) else { return nil }
        return smooth(old: previous, new: canonical)
    }
}

/// A short transition between already aligned, accepted plane-space shapes.
/// It never interpolates camera pose or screen coordinates.
struct LiveContourBlend {
    let from: [[CGPoint]]
    let to: [[CGPoint]]
    let startedAt: TimeInterval
    let duration: TimeInterval

    init?(from: [[CGPoint]], to: [[CGPoint]], startedAt: TimeInterval, duration: TimeInterval = 0.18) {
        guard !from.isEmpty, from.count == to.count,
              zip(from, to).allSatisfy({ $0.count >= 3 && $0.count == $1.count }),
              startedAt.isFinite, duration.isFinite, duration > 0 else { return nil }
        self.from = from; self.to = to; self.startedAt = startedAt; self.duration = duration
    }
    func value(at now: TimeInterval) -> [[CGPoint]] {
        let progress = min(1, max(0, (now-startedAt)/duration))
        if progress <= 0 { return from }
        if progress >= 1 { return to }
        let t = CGFloat(progress*progress*(3-2*progress))
        return zip(from, to).map { a, b in
            zip(a, b).map { CGPoint(x: $0.x+($1.x-$0.x)*t, y: $0.y+($1.y-$0.y)*t) }
        }
    }
}
