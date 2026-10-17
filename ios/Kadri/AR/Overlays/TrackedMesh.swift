import SwiftUI
import KadriCore

/// Geometry in a fixed 1024-unit image space; only the affine mapping changes per frame.
struct TrackedMesh: Sendable, Identifiable {
    let id: String
    let mesh: TriangulatedMesh
    let referenceBox: CGRect

    func transform(to box: CGRect) -> CGAffineTransform? {
        ContourGeometry.transform(from: referenceBox.applying(CGAffineTransform(scaleX: 1024, y: 1024)), to: box)
    }

    static func state(id: String, step: Step?) -> MeshWrap.State {
        if step?.avoid.contains(id) == true { return .avoid }
        if step?.focus.contains(id) == true { return .focus }
        return .idle
    }
}

/// Actor isolation keeps triangulation off the UI executor. Identical segmentation reuses geometry.
actor TrackedMeshCache {
    private var entries: [String: (polygons: [[CGPoint]], mesh: TriangulatedMesh)] = [:]
    private(set) var buildCount = 0

    func mesh(for contour: TrackedContour) -> TrackedMesh {
        let mesh: TriangulatedMesh
        if let entry = entries[contour.id], entry.polygons == contour.polygons { mesh = entry.mesh }
        else {
            mesh = MeshTriangulation.triangulate(polygons: contour.polygons.map { $0.map {
                CGPoint(x: $0.x * 1024, y: $0.y * 1024)
            } })
            entries[contour.id] = (contour.polygons, mesh)
            buildCount += 1
        }
        return TrackedMesh(id: contour.id, mesh: mesh, referenceBox: contour.referenceBox)
    }
}

struct TrackedMeshOverlay: View {
    let meshes: [TrackedMesh]
    let boxes: [String: CGRect]
    var step: Step?

    private var visible: [(item: TrackedMesh, transform: CGAffineTransform)] {
        meshes.compactMap { item in
            guard item.mesh.triangleCount > 0, let box = boxes[item.id],
                  let transform = item.transform(to: box) else { return nil }
            return (item, transform)
        }
    }

    var body: some View {
        let items = visible
        let highlighted = items.filter { TrackedMesh.state(id: $0.item.id, step: step) != .idle }
        ZStack {
            // Keep identity while temporarily offscreen so returning to view never restarts the scan.
            ForEach(meshes) { item in
                let mapping = items.first { $0.item.id == item.id }?.transform
                MeshWrap(mesh: item.mesh, transform: mapping ?? .identity,
                         state: TrackedMesh.state(id: item.id, step: step), appeared: true)
                    .opacity(mapping == nil ? 0 : 1)
            }
        }
        .modifier(SpotlightDim(meshes: highlighted.map(\.item.mesh), transform: .identity,
                               active: !highlighted.isEmpty, transforms: highlighted.map(\.transform)))
        .allowsHitTesting(false)
    }
}
