import Foundation

/// Immutable keyframe-pixel geometry. Rings use an even-odd fill (including holes).
/// Cache this value when segmentation changes; camera motion only changes the view transform.
public struct TriangulatedMesh: Sendable, Equatable {
    public let vertices: [CGPoint]
    public let triangleIndices: [Int]
    public let outlines: [[CGPoint]]
    public let bounds: CGRect
    public var triangleCount: Int { triangleIndices.count / 3 }
    /// Largest ring, for callers that need a single outline. Rendering must use `outlines`.
    public var outline: [CGPoint] { outlines.max { ContourGeometry.area($0) < ContourGeometry.area($1) } ?? [] }
    public static let empty = TriangulatedMesh(vertices: [], triangleIndices: [], outlines: [], bounds: .null)
}

public enum MeshTriangulation {
    public struct Configuration: Sendable {
        /// Square grid split along the rising diagonal, matching the design's SVG pattern.
        public var cellFraction: CGFloat
        public var maximumTriangles: Int
        public var snapFraction: CGFloat
        public init(cellFraction: CGFloat = 0.07, maximumTriangles: Int = 600, snapFraction: CGFloat = 0.45) {
            self.cellFraction = cellFraction
            self.maximumTriangles = maximumTriangles
            self.snapFraction = snapFraction
        }
    }

    /// Row-major 0/255 pixels, top-left origin. Malformed/empty inputs produce an empty mesh.
    /// Pixel-exact boundary extraction; simplification affects the outline by at most 0.75 px.
    public static func triangulate(width: Int, height: Int, pixels: [UInt8],
                                   configuration: Configuration = .init()) -> TriangulatedMesh {
        guard width > 0, height > 0, width < Int.max / height,
              pixels.count == width * height, width < Int.max / (height + 1) - 1 else { return .empty }
        let rings = contours(width: width, height: height, pixels: pixels)
        guard !rings.isEmpty else { return .empty }
        return build(rings: rings, configuration: configuration) { p in
            guard p.x >= 0, p.y >= 0, p.x < CGFloat(width), p.y < CGFloat(height) else { return false }
            return pixels[Int(p.y) * width + Int(p.x)] > 127
        }
    }

    /// Rings may be concave, disconnected, or nested holes. They need not repeat the first vertex.
    public static func triangulate(polygons: [[CGPoint]],
                                   configuration: Configuration = .init()) -> TriangulatedMesh {
        let rings = polygons.compactMap { input -> [CGPoint]? in
            var ring = input
            if ring.first == ring.last { ring.removeLast() }
            guard ring.count >= 3, ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  ContourGeometry.area(ring) > 0 else { return nil }
            return ring
        }
        return build(rings: rings, configuration: configuration) { contains($0, rings: rings) }
    }

    private static func build(rings: [[CGPoint]], configuration: Configuration,
                              contains: (CGPoint) -> Bool) -> TriangulatedMesh {
        let bounds = ContourGeometry.bounds(rings.flatMap { $0 })
        guard ContourGeometry.valid(bounds), configuration.maximumTriangles > 0,
              configuration.cellFraction.isFinite, configuration.cellFraction > 0,
              configuration.snapFraction.isFinite else { return .empty }
        let budget = min(10_000, configuration.maximumTriangles)
        guard budget >= 2 else { return .empty }
        var cell = max(bounds.width * configuration.cellFraction,
                       sqrt(bounds.width * bounds.height * 2 / CGFloat(budget)))
        // Bound work as well as output. Coarsen the whole grid, never truncate one side of the object.
        while ceil(bounds.width / cell) * ceil(bounds.height / cell) * 2 > CGFloat(budget) { cell *= 1.025 }
        let columns = max(1, Int(ceil(bounds.width / cell)))
        let rows = max(1, Int(ceil(bounds.height / cell)))
        let dx = bounds.width / CGFloat(columns), dy = bounds.height / CGFloat(rows)
        let snapDistance = min(dx, dy) * min(0.49, max(0, configuration.snapFraction))
        // Index contour segments by the grid vertices they can attract. Camera masks often
        // have hundreds of boundary segments; testing every segment at every vertex wastes work.
        let segments = rings.flatMap { ring in
            ring.indices.map { Segment(a: ring[$0], b: ring[($0+1)%ring.count]) }
        }
        var candidates = [[Int]](repeating: [], count: (columns+1)*(rows+1))
        var cellSegments = [[Int]](repeating: [], count: columns*rows)
        for (index, segment) in segments.enumerated() {
            let x0 = max(0,Int(ceil((min(segment.a.x,segment.b.x)-snapDistance-bounds.minX)/dx)))
            let x1 = min(columns,Int(floor((max(segment.a.x,segment.b.x)+snapDistance-bounds.minX)/dx)))
            let y0 = max(0,Int(ceil((min(segment.a.y,segment.b.y)-snapDistance-bounds.minY)/dy)))
            let y1 = min(rows,Int(floor((max(segment.a.y,segment.b.y)+snapDistance-bounds.minY)/dy)))
            if x0 <= x1, y0 <= y1 {
                for y in y0...y1 {
                    for x in x0...x1 { candidates[y*(columns+1)+x].append(index) }
                }
            }
            let cx0 = max(0,Int(floor((min(segment.a.x,segment.b.x)-snapDistance-bounds.minX)/dx)))
            let cx1 = min(columns-1,Int(floor((max(segment.a.x,segment.b.x)+snapDistance-bounds.minX)/dx)))
            let cy0 = max(0,Int(floor((min(segment.a.y,segment.b.y)-snapDistance-bounds.minY)/dy)))
            let cy1 = min(rows-1,Int(floor((max(segment.a.y,segment.b.y)+snapDistance-bounds.minY)/dy)))
            if cx0 <= cx1, cy0 <= cy1 {
                for y in cy0...cy1 {
                    for x in cx0...cx1 { cellSegments[y*columns+x].append(index) }
                }
            }
        }
        var grid: [CGPoint] = []
        var usable: [Bool] = []
        for y in 0...rows {
            for x in 0...columns {
                let point = CGPoint(x: bounds.minX + CGFloat(x) * dx, y: bounds.minY + CGFloat(y) * dy)
                let nearest = nearestPoint(point, segments: segments, candidates: candidates[y*(columns+1)+x])
                let snapped = nearest.distance <= snapDistance
                grid.append(snapped ? nearest.point : point)
                usable.append(snapped || contains(point))
            }
        }
        var indices: [Int] = []
        func add(_ a: Int, _ b: Int, _ c: Int, cellIndex: Int) {
            guard usable[a], usable[b], usable[c] else { return }
            let p = grid[a], q = grid[b], r = grid[c]
            let cross = (q.x-p.x)*(r.y-p.y) - (q.y-p.y)*(r.x-p.x)
            guard cross > 0.00001 else { return }
            let center = CGPoint(x: (p.x+q.x+r.x)/3, y: (p.y+q.y+r.y)/3)
            guard contains(center) else { return }
            // Reject crossing a concavity/hole. Slightly inset edge samples allow boundary pixels.
            for (u,v) in [(p,q),(q,r),(r,p)] {
                for t in [CGFloat(0.25), 0.5, 0.75] {
                    let edge = CGPoint(x: u.x + (v.x-u.x)*t, y: u.y + (v.y-u.y)*t)
                    let inset = CGPoint(x: edge.x*0.999 + center.x*0.001, y: edge.y*0.999 + center.y*0.001)
                    guard contains(inset) else { return }
                }
            }
            // Sampling alone can miss a sub-cell hole. Reject any contour segment crossing
            // the triangle interior, including a tiny complete ring contained by one triangle.
            for index in cellSegments[cellIndex] {
                let segment = segments[index]
                if strictlyInside(segment.a,p,q,r) || strictlyInside(segment.b,p,q,r)
                    || crosses(segment.a,segment.b,p,q) || crosses(segment.a,segment.b,q,r)
                    || crosses(segment.a,segment.b,r,p) { return }
            }
            indices.append(contentsOf: [a,b,c])
        }
        for y in 0..<rows {
            for x in 0..<columns {
                let a = y*(columns+1)+x, b = a+1, c = a+columns+1, d = c+1
                add(a,b,c,cellIndex: y*columns+x)
                add(b,d,c,cellIndex: y*columns+x)
            }
        }
        var remap = [Int](repeating: -1, count: grid.count)
        var vertices: [CGPoint] = []
        for i in indices.indices {
            let old = indices[i]
            if remap[old] < 0 { remap[old] = vertices.count; vertices.append(grid[old]) }
            indices[i] = remap[old]
        }
        return TriangulatedMesh(vertices: vertices, triangleIndices: indices, outlines: rings, bounds: bounds)
    }

    private static func side(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
    }

    private static func strictlyInside(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
        side(p,a,b) > 0.00001 && side(p,b,c) > 0.00001 && side(p,c,a) > 0.00001
    }

    private static func crosses(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        let ac = side(c,a,b), ad = side(d,a,b), ca = side(a,c,d), cb = side(b,c,d)
        return ((ac > 0.00001 && ad < -0.00001) || (ac < -0.00001 && ad > 0.00001))
            && ((ca > 0.00001 && cb < -0.00001) || (ca < -0.00001 && cb > 0.00001))
    }

    private struct Segment {
        let a: CGPoint
        let b: CGPoint
        let dx: CGFloat
        let dy: CGFloat
        let inverseLength: CGFloat
        init(a: CGPoint,b: CGPoint) {
            self.a = a; self.b = b
            dx = b.x-a.x; dy = b.y-a.y
            let length = dx*dx+dy*dy
            inverseLength = length > 0 ? 1/length : 0
        }
    }

    private static func nearestPoint(_ p: CGPoint, segments: [Segment], candidates: [Int]) -> (point: CGPoint, distance: CGFloat) {
        var best = p, squared = CGFloat.infinity
        for index in candidates {
            let s = segments[index]
            let t = min(1,max(0,((p.x-s.a.x)*s.dx+(p.y-s.a.y)*s.dy)*s.inverseLength))
            let q = CGPoint(x: s.a.x+t*s.dx, y: s.a.y+t*s.dy)
            let d = (q.x-p.x)*(q.x-p.x)+(q.y-p.y)*(q.y-p.y)
            if d < squared { squared = d; best = q }
        }
        return (best,sqrt(squared))
    }

    private static func contains(_ p: CGPoint, rings: [[CGPoint]]) -> Bool {
        var inside = false
        for ring in rings {
            for i in ring.indices {
                let a = ring[i], b = ring[(i+1) % ring.count]
                if (a.y > p.y) != (b.y > p.y),
                   p.x < (b.x-a.x)*(p.y-a.y)/(b.y-a.y)+a.x { inside.toggle() }
            }
        }
        return inside
    }

    private static func contours(width: Int, height: Int, pixels: [UInt8]) -> [[CGPoint]] {
        // Directed exposed pixel edges. Foreground stays on the right; right turns separate
        // diagonally touching components. Insertion/traversal order is stable (no Set iteration).
        let stride = width+1
        var starts: [Int] = [], ends: [Int] = []
        var outgoing: [Int: [Int]] = [:]
        func edge(_ a: Int, _ b: Int) {
            outgoing[a, default: []].append(starts.count)
            starts.append(a); ends.append(b)
        }
        // Vectorized run discovery avoids a Swift per-pixel loop over a camera-sized bitmap.
        // The public contract is binary 0/255, as produced by Segmenter.
        var runs = [[Range<Int>]](repeating: [], count: height)
        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            for y in 0..<height {
                let row = base.advanced(by: y*width)
                var x = 0
                while x < width, let start = memchr(row.advanced(by: x), 255, width-x) {
                    let lower = row.distance(to: start)
                    let end = memchr(row.advanced(by: lower), 0, width-lower)
                    let upper = end.map { row.distance(to: $0) } ?? width
                    runs[y].append(lower..<upper)
                    x = upper
                }
            }
        }
        func exposed(_ run: Range<Int>, against neighbors: [Range<Int>], y: Int, bottom: Bool) {
            var cursor = run.lowerBound
            func segment(_ lower: Int, _ upper: Int) {
                guard lower < upper else { return }
                let a = y*stride+lower, b = y*stride+upper
                if bottom { edge(b,a) } else { edge(a,b) }
            }
            for neighbor in neighbors {
                if neighbor.upperBound <= cursor { continue }
                if neighbor.lowerBound >= run.upperBound { break }
                segment(cursor,min(run.upperBound,neighbor.lowerBound))
                cursor = max(cursor,neighbor.upperBound)
                if cursor >= run.upperBound { break }
            }
            segment(cursor,run.upperBound)
        }
        for y in 0..<height {
            for run in runs[y] {
                edge((y+1)*stride+run.lowerBound,y*stride+run.lowerBound)
                edge(y*stride+run.upperBound,(y+1)*stride+run.upperBound)
                exposed(run,against: y > 0 ? runs[y-1] : [],y: y,bottom: false)
                exposed(run,against: y+1 < height ? runs[y+1] : [],y: y+1,bottom: true)
            }
        }
        var visited = [Bool](repeating: false, count: starts.count)
        var rings: [[CGPoint]] = []
        func direction(_ i: Int) -> Int {
            let x0 = starts[i] % stride, x1 = ends[i] % stride
            if x1 > x0 { return 0 }
            if ends[i] > starts[i] { return 1 }
            if x1 < x0 { return 2 }
            return 3
        }
        for start in starts.indices where !visited[start] {
            var ring: [CGPoint] = [], current = start
            while !visited[current] {
                visited[current] = true
                let a = starts[current]
                ring.append(CGPoint(x: a % stride, y: a / stride))
                if ends[current] == starts[start] { break }
                let candidates = (outgoing[ends[current]] ?? []).filter { !visited[$0] }
                let dir = direction(current)
                func rank(_ candidate: Int) -> Int {
                    switch (direction(candidate)-dir+4)%4 {
                    case 1: return 0
                    case 0: return 1
                    case 3: return 2
                    default: return 3
                    }
                }
                guard let next = candidates.min(by: { rank($0) < rank($1) }) else { break }
                current = next
            }
            if ring.count >= 3 {
                rings.append(ContourGeometry.simplify(ring, tolerance: 0.75))
            }
        }
        return rings
    }
}
