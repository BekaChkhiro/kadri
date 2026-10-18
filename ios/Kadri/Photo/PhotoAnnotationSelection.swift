import Foundation
import KadriCore

/// One budget for moving glyphs. Amounts and tightening order remain readable metadata.
struct PhotoAnnotationSelection {
    let arrows: [StepArrow]
    let actions: [StepAction]
    let markers: [StepMarker]
    let orderNumbers: [String: Int]

    @MainActor static func make(step: Step, parts: [Part], boxes: [String: CGRect],
                     sizeBoxes: [String: CGRect]? = nil, viewport: CGSize) -> Self {
        let allArrows = PhotoArrowLayout.make(arrows: step.arrows, boxes: boxes,
            sizeBoxes: sizeBoxes, avoid: step.avoid, viewport: viewport, limit: Int.max)
        let explicitParts = Set(allArrows.map(\.id))
        let chosen = Array(allArrows.prefix(3))
        let arrows = chosen.map { layout in
            StepArrow(part: layout.id, type: layout.kind.arrow.type, dir: layout.kind.arrow.dir)
        }
        var used = Set(chosen.map(\.id))
        var actions: [StepAction] = []
        func visible(_ part: String) -> Bool {
            !PhotoArrowLayout.make(arrows: [.init(part: part, type: "move", dir: "up")],
                boxes: boxes, avoid: step.avoid, viewport: viewport).isEmpty
        }
        for action in step.actions ?? [] {
            guard used.count < 3, action.kind != "tighten_order",
                  PhotoActionOverlays.kinds.contains(action.kind),
                  !explicitParts.contains(action.part), !used.contains(action.part),
                  visible(action.part) else { continue }
            actions.append(action)
            used.insert(action.part)
        }
        var markers = step.markers
        var numbers: [String: Int] = [:]
        func ensureMarker(_ part: String, suffix: String? = nil) {
            if let index = markers.firstIndex(where: { $0.part == part }) {
                if let suffix {
                    let marker = markers[index]
                    markers[index] = .init(part: part, label: "\(suffix) · \(marker.label)", tone: marker.tone)
                }
            } else if let name = parts.first(where: { $0.id == part })?.name {
                markers.append(.init(part: part, label: suffix.map { "\($0) · \(name)" } ?? name))
            }
        }
        for action in step.actions ?? [] {
            if action.kind == "tighten_order" {
                // Keep original positions even when a target is offscreen; never renumber a partial sequence.
                for (index, part) in (action.order ?? []).enumerated() where visible(part) {
                    if numbers[part] == nil { numbers[part] = index + 1 }
                    ensureMarker(part, suffix: action.amount == "hand_tight_plus_quarter" ? "ხელით + ¼ ბრუნი" : nil)
                }
            } else if let amount = action.amount,
                      chosen.contains(where: { $0.id == action.part &&
                          ((action.kind == "rotate_cw" && $0.kind == .clockwise) ||
                           (action.kind == "rotate_ccw" && $0.kind == .counterclockwise)) }) {
                let label = amount == "hand_tight_plus_quarter" ? "ხელით + ¼ ბრუნი" : "\(amount) ბრუნი"
                ensureMarker(action.part, suffix: label)
            }
        }
        return .init(arrows: arrows, actions: actions, markers: markers, orderNumbers: numbers)
    }
}
