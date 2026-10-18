import UIKit
import XCTest
@testable import Kadri

final class PhotoCameraTests: XCTestCase {
    /// 400×300 landscape pixels; .right makes the UIImage a 300×400 portrait, as the camera delivers it.
    private func landscape(orientation: UIImage.Orientation) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let cg = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
            UIColor.blue.setFill(); context.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        }.cgImage!
        return UIImage(cgImage: cg, scale: 1, orientation: orientation)
    }

    func testPhotoSessionCropsToSquare() {
        let image = PhotoCaptureCamera.prepared(landscape(orientation: .up), fullFrame: false)
        XCTAssertEqual(image.size, CGSize(width: 300, height: 300))
    }

    func testFullFrameKeepsLandscapeAspect() {
        let image = PhotoCaptureCamera.prepared(landscape(orientation: .up), fullFrame: true)
        XCTAssertEqual(image.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(image.imageOrientation, .up)
    }

    func testFullFrameBakesInOrientation() {
        let image = PhotoCaptureCamera.prepared(landscape(orientation: .right), fullFrame: true)
        XCTAssertEqual(image.size, CGSize(width: 300, height: 400))
        XCTAssertEqual(image.imageOrientation, .up)
        let cg = image.cgImage!
        XCTAssertEqual(cg.width, 300)
        XCTAssertEqual(cg.height, 400)
    }
}
