import ImageIO
import UIKit

/// Prepares an entire evidence photo. Cropping would lose labels and relationships at its edges.
enum ProblemPhotoImport {
    static let maximumSourceBytes = 30 * 1024 * 1024
    static let maximumJPEGBytes = 2 * 1024 * 1024
    static let maximumSide = 768

    enum ImportError: LocalizedError {
        case sourceTooLarge, unreadableImage, encodingFailed

        var errorDescription: String? {
            switch self {
            case .sourceTooLarge: return "ფოტოს ზომა 30 მბ-ს არ უნდა აღემატებოდეს."
            case .unreadableImage: return "ფოტო ვერ გაიხსნა. აირჩიე სხვა გამოსახულება."
            case .encodingFailed: return "ფოტოს მომზადება ვერ მოხერხდა. სცადე სხვა ფოტო."
            }
        }
    }

    /// ImageIO downsamples before decoding the full image, including camera HEIC files.
    static func jpeg(from data: Data) throws -> Data {
        guard data.count <= maximumSourceBytes else { throw ImportError.sourceTooLarge }
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0 else {
            throw ImportError.unreadableImage
        }
        let side = min(Double(maximumSide), max(width.doubleValue, height.doubleValue))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: side,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ImportError.unreadableImage
        }
        return try jpeg(from: UIImage(cgImage: thumbnail))
    }

    /// Drawing bakes in all eight UIImage orientations, including mirrored camera images.
    static func jpeg(from image: UIImage) throws -> Data {
        let rawSize: CGSize
        if let cgImage = image.cgImage {
            rawSize = CGSize(width: cgImage.width, height: cgImage.height)
        } else if let ciImage = image.ciImage {
            rawSize = ciImage.extent.size
        } else {
            throw ImportError.unreadableImage
        }
        guard rawSize.width.isFinite, rawSize.height.isFinite,
              rawSize.width > 0, rawSize.height > 0 else { throw ImportError.unreadableImage }
        let swapsAxes: Bool
        switch image.imageOrientation {
        case .left, .right, .leftMirrored, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let oriented = swapsAxes ? CGSize(width: rawSize.height, height: rawSize.width) : rawSize
        let scale = min(1, CGFloat(maximumSide) / max(oriented.width, oriented.height))
        let size = CGSize(width: max(1, floor(oriented.width * scale)), height: max(1, floor(oriented.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let prepared = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        for quality in [0.85, 0.65, 0.45] {
            if let jpeg = prepared.jpegData(compressionQuality: quality), !jpeg.isEmpty, jpeg.count <= maximumJPEGBytes {
                return jpeg
            }
        }
        throw ImportError.encodingFailed
    }
}
