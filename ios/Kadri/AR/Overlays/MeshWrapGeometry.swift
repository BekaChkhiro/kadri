import SwiftUI
import KadriCore

/// Prebuilt paths, independent of the AR transform. Construct only for a new SAM result.
struct MeshWrapGeometry {
    let outline: Path
    let wireframe: Path
    let bounds: CGRect
    static let empty = MeshWrapGeometry(mesh: .empty)

    init(mesh: TriangulatedMesh) {
        bounds = mesh.bounds
        outline = Path { path in
            for ring in mesh.outlines {
                guard let first = ring.first else { continue }
                path.move(to: first)
                for p in ring.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
        }
        struct Edge: Hashable {
            let a: Int
            let b: Int
            init(_ a: Int, _ b: Int) { self.a = min(a,b); self.b = max(a,b) }
        }
        wireframe = Path { path in
            var seen: Set<Edge> = []
            for i in stride(from: 0, to: mesh.triangleIndices.count, by: 3) {
                let triangle = Array(mesh.triangleIndices[i..<i+3])
                for j in 0..<3 {
                    let edge = Edge(triangle[j], triangle[(j+1)%3])
                    if seen.insert(edge).inserted {
                        path.move(to: mesh.vertices[edge.a])
                        path.addLine(to: mesh.vertices[edge.b])
                    }
                }
            }
        }
    }
}

/// CPU command-encoding timing only; GPU completion/frame rate must be checked on device.
/// Kept internal so hosted tests can observe the real Canvas callback without a global recorder.
struct MeshWrapDrawObserverKey: EnvironmentKey {
    static let defaultValue: (@Sendable (Double) -> Void)? = nil
}
extension EnvironmentValues {
    var meshWrapDrawObserver: (@Sendable (Double) -> Void)? {
        get { self[MeshWrapDrawObserverKey.self] }
        set { self[MeshWrapDrawObserverKey.self] = newValue }
    }
}

/// Test/preview opt-in only; it can never disable the system's Reduce Motion setting.
private struct MeshWrapReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var meshWrapReduceMotion: Bool {
        get { self[MeshWrapReducedMotionKey.self] }
        set { self[MeshWrapReducedMotionKey.self] = newValue }
    }
}
