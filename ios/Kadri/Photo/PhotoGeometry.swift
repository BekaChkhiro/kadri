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
}
