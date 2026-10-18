import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import Kadri

final class ProblemPhotoImportTests: XCTestCase {
    private func landmarks(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 4, height: height / 4))
            UIColor.blue.setFill()
            context.fill(CGRect(x: width * 3 / 4, y: height * 3 / 4, width: width / 4, height: height / 4))
        }
    }

    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) -> [UInt8] {
        let cg = image.cgImage!
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: colorSpace,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let offset = (Int(CGFloat(cg.height) * y) * cg.width + Int(CGFloat(cg.width) * x)) * 4
        return Array(bytes[offset..<(offset + 3)])
    }

    private func assertRed(_ color: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(color[0], 180, file: file, line: line)
        XCTAssertLessThan(color[2], 70, file: file, line: line)
    }

    private func assertBlue(_ color: [UInt8], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(color[2], 180, file: file, line: line)
        XCTAssertLessThan(color[0], 70, file: file, line: line)
    }

    func testWideAndTallPhotosPreserveBothEdgeLandmarks() throws {
        for (width, height) in [(1600, 800), (800, 1600)] {
            let source = landmarks(width: width, height: height)
            for jpeg in [try ProblemPhotoImport.jpeg(from: source), try ProblemPhotoImport.jpeg(from: XCTUnwrap(source.pngData()))] {
                let output = try XCTUnwrap(UIImage(data: jpeg))
                XCTAssertEqual(output.cgImage!.width, width * 768 / 1600)
                XCTAssertEqual(output.cgImage!.height, height * 768 / 1600)
                XCTAssertEqual(output.imageOrientation, .up)
                XCTAssertLessThanOrEqual(jpeg.count, ProblemPhotoImport.maximumJPEGBytes)
                assertRed(pixel(output, x: 0.1, y: 0.1))
                assertBlue(pixel(output, x: 0.9, y: 0.9))
            }
        }
    }

    func testImageOrientationRotatesPixelsAndDimensions() throws {
        let source = UIImage(cgImage: landmarks(width: 400, height: 200).cgImage!, scale: 2, orientation: .right)
        let output = try XCTUnwrap(UIImage(data: ProblemPhotoImport.jpeg(from: source)))
        XCTAssertEqual(output.size, CGSize(width: 200, height: 400))
        XCTAssertEqual(output.imageOrientation, .up)
        assertRed(pixel(output, x: 0.9, y: 0.1))
        assertBlue(pixel(output, x: 0.1, y: 0.9))
    }

    func testMirroredImageOrientationBakesInReflection() throws {
        let source = UIImage(cgImage: landmarks(width: 400, height: 200).cgImage!, scale: 1, orientation: .upMirrored)
        let output = try XCTUnwrap(UIImage(data: ProblemPhotoImport.jpeg(from: source)))
        assertRed(pixel(output, x: 0.9, y: 0.1))
        assertBlue(pixel(output, x: 0.1, y: 0.9))
    }

    func testEncodedEXIFOrientationIsAppliedDuringDownsampling() throws {
        let source = landmarks(width: 1600, height: 800).cgImage!
        // EXIF 1...8 cover rotations and each mirrored counterpart.
        let redCorners: [(CGFloat, CGFloat)] = [(0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9),
                                               (0.1, 0.1), (0.9, 0.1), (0.9, 0.9), (0.1, 0.9)]
        let orientations: [UIImage.Orientation] = [.up, .upMirrored, .down, .downMirrored,
                                                  .leftMirrored, .right, .rightMirrored, .left]
        for exif in 1...8 {
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: exif] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let oriented = UIImage(cgImage: source, scale: 1, orientation: orientations[exif - 1])
            for jpeg in [try ProblemPhotoImport.jpeg(from: data as Data), try ProblemPhotoImport.jpeg(from: oriented)] {
                let output = try XCTUnwrap(UIImage(data: jpeg))
                XCTAssertEqual(output.size, exif >= 5 ? CGSize(width: 384, height: 768) : CGSize(width: 768, height: 384))
                XCTAssertEqual(output.imageOrientation, .up)
                let (x, y) = redCorners[exif - 1]
                assertRed(pixel(output, x: x, y: y))
                assertBlue(pixel(output, x: 1 - x, y: 1 - y))
            }
        }
    }

    func testSmallImageIsNotUpscaled() throws {
        let source = landmarks(width: 120, height: 80)
        for data in [try ProblemPhotoImport.jpeg(from: source), try ProblemPhotoImport.jpeg(from: XCTUnwrap(source.pngData()))] {
            XCTAssertEqual(UIImage(data: data)?.size, CGSize(width: 120, height: 80))
        }
    }

    func testInvalidAndEmptyInputAreRejected() {
        for data in [Data(), Data("not an image".utf8)] {
            XCTAssertThrowsError(try ProblemPhotoImport.jpeg(from: data)) { error in
                guard case ProblemPhotoImport.ImportError.unreadableImage = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        }
        XCTAssertThrowsError(try ProblemPhotoImport.jpeg(from: UIImage()))
    }

    func testOversizedSourceIsRejectedBeforeDecoding() {
        XCTAssertThrowsError(try ProblemPhotoImport.jpeg(from: Data(count: ProblemPhotoImport.maximumSourceBytes + 1))) { error in
            guard case ProblemPhotoImport.ImportError.sourceTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }
}
