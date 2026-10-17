import Foundation
import KadriCore

enum PhotoGeometry {
    static func imageRect(viewport: CGSize, imageSize: CGSize) -> CGRect {
        guard viewport.width.isFinite, viewport.height.isFinite,
              imageSize.width.isFinite, imageSize.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = max(viewport.width / imageSize.width, viewport.height / imageSize.height)
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

    /// Container coordinates start immediately below the header. Leave a gap above the measured card.
    static func visibleRect(viewport: CGSize, cardHeight: CGFloat, bottomInset: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: max(0, viewport.width),
               height: max(0, viewport.height - max(0, cardHeight) - max(0, bottomInset) - 16))
    }

    /// Image-pixel coordinates → container points. Zoom is capped at three times aspect-fill.
    static func focusTransform(imageSize: CGSize, viewport: CGSize, visibleRect: CGRect,
                               focusBoxes: [CGRect]) -> CGAffineTransform {
        let cover = imageRect(viewport: viewport, imageSize: imageSize)
        guard !cover.isEmpty else { return .identity }
        let minimum = cover.width / imageSize.width
        let fallback = CGAffineTransform(a: minimum, b: 0, c: 0, d: minimum, tx: cover.minX, ty: cover.minY)
        let imageBounds = CGRect(origin: .zero, size: imageSize)
        let union = focusBoxes.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
            .map { $0.intersection(imageBounds) }.reduce(CGRect.null) { $0.union($1) }
        let visible = visibleRect.intersection(CGRect(origin: .zero, size: viewport))
        guard !union.isEmpty, !union.isNull, !visible.isEmpty, !visible.isNull else { return fallback }
        // 25% extra space around the union, then center within the unobscured area.
        let fit = min(visible.width / (union.width * 1.25), visible.height / (union.height * 1.25))
        let scale = min(minimum * 3, max(minimum, fit))
        let tx = min(0, max(viewport.width - imageSize.width * scale, visible.midX - union.midX * scale))
        let ty = min(0, max(viewport.height - imageSize.height * scale, visible.midY - union.midY * scale))
        return CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: tx, ty: ty)
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
