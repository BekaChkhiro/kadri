import SwiftUI
import QuartzCore
import KadriCore

struct MeshWrap: View {
    enum State: String, CaseIterable { case idle, focus, avoid }

    let mesh: TriangulatedMesh
    let transform: CGAffineTransform
    let state: State
    let appeared: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.meshWrapReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @Environment(\.meshWrapSpotlightActive) private var spotlightActive
    @SwiftUI.State private var geometry = MeshWrapGeometry.empty
    @SwiftUI.State private var scan: Double = 0
    @SwiftUI.State private var scanned = false

    init(mesh: TriangulatedMesh, transform: CGAffineTransform, state: State, appeared: Bool) {
        self.mesh = mesh
        self.transform = transform
        self.state = state
        self.appeared = appeared
    }

    var body: some View {
        MeshWrapDrawing(geometry: geometry, transform: transform,
                        scan: scan, emphasis: scanned && state != .idle ? 1 : 0,
                        danger: scanned && state == .avoid ? 1 : 0,
                        subdued: spotlightActive && state == .idle ? 1 : 0,
                        showScan: !reduceMotion)
            .opacity(appeared ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: state)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: spotlightActive)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: scanned)
            .onChange(of: mesh, initial: true) { _, mesh in
                geometry = MeshWrapGeometry(mesh: mesh)
            }
            .task(id: appeared) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scan = reduceMotion && appeared ? 1 : 0
                    scanned = reduceMotion && appeared
                }
                guard appeared, !reduceMotion else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 1.3)) { scan = 1 }
                do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
                guard !Task.isCancelled else { return }
                scanned = true
            }
            .onChange(of: reduceMotion) { _, reduced in
                if reduced {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { scan = appeared ? 1 : 0; scanned = appeared }
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}

private struct MeshWrapDrawing: View, Animatable {
    let geometry: MeshWrapGeometry
    let transform: CGAffineTransform
    nonisolated var scan: Double
    nonisolated var emphasis: Double
    nonisolated var danger: Double
    nonisolated var subdued: Double
    let showScan: Bool
    @Environment(\.meshWrapDrawObserver) private var observer

    nonisolated var animatableData: AnimatablePair<AnimatablePair<Double,Double>, AnimatablePair<Double,Double>> {
        get { .init(.init(scan,emphasis),.init(danger,subdued)) }
        set {
            scan = newValue.first.first; emphasis = newValue.first.second
            danger = newValue.second.first; subdued = newValue.second.second
        }
    }

    var body: some View {
        Canvas { context, _ in
            let start = CACurrentMediaTime()
            defer { observer?((CACurrentMediaTime()-start)*1000) }
            guard !geometry.bounds.isNull, scan > 0,
                  [transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty].allSatisfy(\.isFinite),
                  abs(transform.a*transform.d-transform.b*transform.c) > 0.000001 else { return }
            // The only keyframe→screen transform; all prebuilt paths stay in keyframe coordinates.
            context.concatenate(transform)
            let scale = sqrt(abs(transform.a*transform.d-transform.b*transform.c))
            // Design's 1024 px photo rendered at 390 pt. Keep stroke weight legible across keyframe sizes.
            let unit = 390.0 / 1024 / scale
            let brand = Theme.Colors.brand[500]!.resolve(in: EnvironmentValues())
            let color = Color(.sRGB,
                              red: Double(brand.red)*(1-danger) + (239.0/255)*danger,
                              green: Double(brand.green)*(1-danger) + (68.0/255)*danger,
                              blue: Double(brand.blue)*(1-danger) + (68.0/255)*danger)
            let fillOpacity = 0.22 + 0.16*emphasis + 0.04*danger
            let y = geometry.bounds.minY + geometry.bounds.height*scan
            let reveal = CGRect(x: geometry.bounds.minX-20*unit, y: geometry.bounds.minY-20*unit,
                                width: geometry.bounds.width+40*unit, height: y-geometry.bounds.minY+20*unit)
            var fill = context
            fill.clip(to: Path(reveal))
            fill.clip(to: geometry.outline, style: FillStyle(eoFill: true))
            fill.opacity = 1 - 0.85*subdued
            fill.fill(geometry.outline, with: .color(color.opacity(fillOpacity)), style: FillStyle(eoFill: true))
            fill.stroke(geometry.wireframe, with: .color(.white.opacity(0.75)), lineWidth: 1.4*unit)

            var outline = context
            outline.clip(to: Path(reveal))
            outline.opacity = 1 - 0.7*subdued
            let width = (3+2*emphasis)*unit
            // Two independent glow layers plus a crisp white core.
            for radius in [3.0, 6+4*emphasis] {
                var glow = outline
                glow.addFilter(.blur(radius: radius*unit))
                glow.stroke(geometry.outline, with: .color(color.opacity(0.9)),
                            style: StrokeStyle(lineWidth: width, lineJoin: .round))
            }
            outline.stroke(geometry.outline, with: .color(.white),
                           style: StrokeStyle(lineWidth: width, lineJoin: .round))
            if showScan, scan < 1 {
                var line = context
                line.clip(to: geometry.outline, style: FillStyle(eoFill: true))
                line.opacity = min(1,(1-scan)/0.15)
                line.addFilter(.shadow(color: color, radius: 10*unit))
                line.fill(Path(CGRect(x: geometry.bounds.minX, y: y-2.5*unit,
                                      width: geometry.bounds.width, height: 5*unit)), with: .color(.white))
            }
        }
    }
}

private struct MeshWrapSpotlightActiveKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var meshWrapSpotlightActive: Bool {
        get { self[MeshWrapSpotlightActiveKey.self] }
        set { self[MeshWrapSpotlightActiveKey.self] = newValue }
    }
}

/// Apply once to the camera+mesh group, before controls. Pass *all* focused/avoid meshes to
/// cut a union of soft holes; stacking this modifier would incorrectly multiply the dimming.
/// In this environment idle meshes use 15% fill/grid and 30% outline (design-system.tsx).
struct SpotlightDim: ViewModifier {
    let meshes: [TriangulatedMesh]
    let transform: CGAffineTransform
    let active: Bool
    let appeared: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.meshWrapReduceMotion) private var previewReduceMotion
    private var reduceMotion: Bool { systemReduceMotion || previewReduceMotion }
    @State private var outlines: [Path] = []
    @State private var scanned = false
    private var isActive: Bool { active && appeared && (scanned || reduceMotion) && !meshes.isEmpty }

    init(meshes: [TriangulatedMesh], transform: CGAffineTransform, active: Bool, appeared: Bool = true) {
        self.meshes = meshes
        self.transform = transform
        self.active = active
        self.appeared = appeared
    }

    func body(content: Content) -> some View {
        content
            .environment(\.meshWrapSpotlightActive, isActive)
            .overlay {
                Canvas { context, size in
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.Colors.ink[950]!))
                    context.blendMode = .destinationOut
                    context.drawLayer { hole in
                        hole.addFilter(.blur(radius: 18*390/1024))
                        for outline in outlines {
                            let path = outline.applying(transform)
                            hole.fill(path, with: .color(.white), style: FillStyle(eoFill: true))
                            hole.stroke(path, with: .color(.white),
                                        style: StrokeStyle(lineWidth: 60*390/1024, lineJoin: .round))
                        }
                    }
                }
                .opacity(isActive ? 0.45 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: isActive)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .task(id: appeared) {
                scanned = reduceMotion && appeared
                guard appeared, !reduceMotion else { return }
                do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
                guard !Task.isCancelled else { return }
                scanned = true
            }
            .onChange(of: meshes, initial: true) { _, meshes in
                outlines = meshes.map { MeshWrapGeometry(mesh: $0).outline }
            }
    }
}
