import Foundation

/// Top-left origin coordinates throughout; polygons omit a repeated closing vertex.
public enum ContourGeometry {
    public static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { result, p in
            CGRect(x: min(result.minX, p.x), y: min(result.minY, p.y),
                   width: max(result.maxX, p.x) - min(result.minX, p.x),
                   height: max(result.maxY, p.y) - min(result.minY, p.y))
        }
    }

    public static func transform(from source: CGRect, to destination: CGRect) -> CGAffineTransform? {
        guard valid(source), valid(destination) else { return nil }
        let sx = destination.width / source.width, sy = destination.height / source.height
        return CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                                 tx: destination.minX - source.minX * sx,
                                 ty: destination.minY - source.minY * sy)
    }

    public static func valid(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) && box.width > 0 && box.height > 0
    }

    /// Movement is relative to the previous segmentation box's dimensions.
    /// Size changes also invalidate a mask, even when its centre stays still.
    public static func shouldResegment(frames: Int, interval: Int = 30,
                                       reference: CGRect, current: CGRect, threshold: CGFloat = 0.2) -> Bool {
        guard valid(reference), valid(current) else { return false }
        return frames >= max(1, interval)
            || abs(current.midX - reference.midX) / reference.width > threshold
            || abs(current.midY - reference.midY) / reference.height > threshold
            || abs(current.width / reference.width - 1) > threshold
            || abs(current.height / reference.height - 1) > threshold
    }

    public static func area(_ polygon: [CGPoint]) -> CGFloat {
        guard polygon.count >= 3 else { return 0 }
        return abs(polygon.indices.reduce(CGFloat.zero) { sum, i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            return sum + a.x * b.y - b.x * a.y
        }) / 2
    }

    /// Closed Douglas–Peucker. Split at a distant vertex to avoid a degenerate baseline.
    public static func simplify(_ polygon: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        var points = polygon
        if points.count > 1, points.first == points.last { points.removeLast() }
        guard points.count > 3, tolerance > 0 else { return points }
        let start = points[0]
        let split = points.indices.dropFirst().max {
            hypot(points[$0].x-start.x, points[$0].y-start.y) < hypot(points[$1].x-start.x, points[$1].y-start.y)
        }!
        func open(_ input: [CGPoint]) -> [CGPoint] {
            guard input.count > 2 else { return input }
            var keep: Set<Int> = [0, input.count-1]
            var stack = [(0, input.count-1)]
            while let (a, b) = stack.popLast() {
                guard b > a + 1 else { continue }
                var distance = tolerance, index: Int?
                for i in (a+1)..<b {
                    let d = segmentDistance(input[i], input[a], input[b])
                    if d > distance { distance = d; index = i }
                }
                if let index { keep.insert(index); stack.append((a,index)); stack.append((index,b)) }
            }
            return keep.sorted().map { input[$0] }
        }
        let result = Array(open(Array(points[...split])).dropLast())
            + Array(open(Array(points[split...]) + [start]).dropLast())
        return result.count >= 3 ? result : points
    }

    public static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x-a.x, dy = b.y-a.y, length = dx*dx + dy*dy
        let t = length > 0 ? min(1, max(0, ((p.x-a.x)*dx + (p.y-a.y)*dy)/length)) : 0
        return hypot(p.x-a.x-t*dx, p.y-a.y-t*dy)
    }
}
