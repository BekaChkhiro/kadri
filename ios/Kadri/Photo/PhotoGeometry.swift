import Foundation
import KadriCore

enum PhotoGeometry {
    struct Pin {
        let part: String
        let size: CGSize
        var prefersBelow = false
    }

    /// Greedy placement in marker order. Keep chips clear, then prefer free space
    /// near the owning box; focus overlap is preferable to overlapping labels.
    static func pinRects(pins: [Pin], boxes: [String: CGRect], focus: [String],
                         viewport: CGSize, visibleHeight: CGFloat, occupiedRects: [CGRect] = []) -> [CGRect?] {
        let height = max(0, min(viewport.height, visibleHeight))
        let top = min(60, height)
        let bounds = CGRect(x: 8, y: top, width: max(0, viewport.width - 16),
                            height: max(0, height - top - 8))
        var placed: [CGRect] = occupiedRects
        return pins.map { pin in
            guard let box = boxes[pin.part], !bounds.isEmpty else { return nil }
            let size = CGSize(width: min(pin.size.width, bounds.width), height: min(pin.size.height, bounds.height))
            func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect {
                CGRect(x: min(max(bounds.minX, x), bounds.maxX - size.width),
                       y: min(max(bounds.minY, y), bounds.maxY - size.height),
                       width: size.width, height: size.height)
            }
            let x = box.midX - size.width / 2
            let above = rect(x, box.minY - size.height - 6)
            let below = rect(x, box.maxY + 6)
            var candidates = pin.prefersBelow ? [below, above] : [above, below]
            candidates += [rect(x, box.minY + 6), rect(x, box.maxY - size.height - 6),
                           rect(box.minX - size.width - 6, box.midY - size.height / 2),
                           rect(box.maxX + 6, box.midY - size.height / 2)]
            // Extra rows resolve clusters whose immediate candidates are all occupied.
            for y in stride(from: bounds.minY, through: bounds.maxY - size.height, by: size.height + 6) {
                candidates += [rect(x, y), rect(bounds.minX, y), rect(bounds.maxX - size.width, y)]
            }
            let others = focus.filter { $0 != pin.part }.compactMap { boxes[$0] }
            func overlap(_ candidate: CGRect, _ obstacles: [CGRect]) -> CGFloat {
                obstacles.reduce(0) { total, obstacle in
                    let intersection = candidate.intersection(obstacle.insetBy(dx: -3, dy: -3))
                    return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
                }
            }
            func distance(_ candidate: CGRect) -> CGFloat {
                let dx = max(0, max(box.minX - candidate.maxX, candidate.minX - box.maxX))
                let dy = max(0, max(box.minY - candidate.maxY, candidate.minY - box.maxY))
                return dx * dx + dy * dy
            }
            let winner = candidates.enumerated().min { lhs, rhs in
                let a = (overlap(lhs.element, placed), overlap(lhs.element, others), distance(lhs.element), lhs.offset)
                let b = (overlap(rhs.element, placed), overlap(rhs.element, others), distance(rhs.element), rhs.offset)
                return a < b
            }!.element
            placed.append(winner)
            return winner
        }
    }

    static func imageRect(viewport: CGSize, imageSize: CGSize) -> CGRect {
        guard viewport.width.isFinite, viewport.height.isFinite,
              imageSize.width.isFinite, imageSize.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        guard size.width.isFinite, size.height.isFinite else { return .zero }
        return CGRect(x: (viewport.width - size.width) / 2, y: (viewport.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    static func boxes(parts: [Part], viewport: CGSize, imageSize: CGSize) -> [String: CGRect] {
        let image = imageRect(viewport: viewport, imageSize: imageSize)
        guard !image.isEmpty else { return [:] }
        return parts.filter(\.hasValidBox).reduce(into: [:]) { result, part in
            let b = part.box.map { CGFloat($0) / 1000 }
            result[part.id] = CGRect(x: image.minX + b[0] * image.width,
                                    y: image.minY + b[1] * image.height,
                                    width: (b[2] - b[0]) * image.width,
                                    height: (b[3] - b[1]) * image.height)
        }
    }

    /// Image-pixel coordinates → photo-area points. Zoom is capped at three times aspect-fit.
    static func focusTransform(imageSize: CGSize, viewport: CGSize, visibleRect: CGRect,
                               focusBoxes: [CGRect]) -> CGAffineTransform {
        let base = imageRect(viewport: viewport, imageSize: imageSize)
        guard !base.isEmpty else { return .identity }
        let minimum = base.width / imageSize.width
        let fallback = CGAffineTransform(a: minimum, b: 0, c: 0, d: minimum, tx: base.minX, ty: base.minY)
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let union = focusBoxes.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            .map { $0.intersection(imageBounds) }.reduce(CGRect.null) { $0.union($1) }
        let visible = visibleRect.intersection(CGRect(origin: .zero, size: viewport))
        guard !union.isEmpty, !union.isNull, !visible.isEmpty, !visible.isNull else { return fallback }
        // 25% extra space around the union, then center within the photo area.
        let fit = min(visible.width / (union.width * 1.25), visible.height / (union.height * 1.25))
        let scale = min(minimum * 3, max(minimum, fit))
        let tx = clampedOffset(length: imageSize.width * scale, viewport: viewport.width, desired: visible.midX - union.midX * scale)
        let ty = clampedOffset(length: imageSize.height * scale, viewport: viewport.height, desired: visible.midY - union.midY * scale)
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
    }

    private static func clampedOffset(length: CGFloat, viewport: CGFloat, desired: CGFloat) -> CGFloat {
        // Letterboxed axes stay centered; enlarged axes cannot reveal an image edge.
        length <= viewport ? (viewport - length) / 2 : min(0, max(viewport - length, desired))
    }

    static func boxes(parts: [Part], imageSize: CGSize, transform: CGAffineTransform) -> [String: CGRect] {
        parts.filter(\.hasValidBox).reduce(into: [:]) { result, part in
            let b = part.box.map { CGFloat($0) / 1000 }
            result[part.id] = CGRect(x: b[0] * imageSize.width, y: b[1] * imageSize.height,
                                    width: (b[2] - b[0]) * imageSize.width,
                                    height: (b[3] - b[1]) * imageSize.height).applying(transform)
        }
    }
}
