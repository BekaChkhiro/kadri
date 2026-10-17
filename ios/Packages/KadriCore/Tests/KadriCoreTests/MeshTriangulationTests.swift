import XCTest
@testable import KadriCore

final class MeshTriangulationTests: XCTestCase {
    private func bitmap(_ width: Int, _ height: Int, includes: (Double,Double) -> Bool) -> [UInt8] {
        (0..<height).flatMap { y in (0..<width).map { x in includes(Double(x)+0.5,Double(y)+0.5) ? UInt8(255) : 0 } }
    }
    private func centroids(_ mesh: TriangulatedMesh) -> [CGPoint] {
        stride(from: 0, to: mesh.triangleIndices.count, by: 3).map { i in
            let points = mesh.triangleIndices[i..<i+3].map { mesh.vertices[$0] }
            return CGPoint(x: points.reduce(0) { $0+$1.x }/3, y: points.reduce(0) { $0+$1.y }/3)
        }
    }

    func testCircleIsInsideDeterministicAndBounded() {
        let pixels = bitmap(160,160) { x,y in hypot(x-80,y-80) <= 70 }
        let mesh = MeshTriangulation.triangulate(width: 160,height: 160,pixels: pixels)
        XCTAssertEqual(mesh, MeshTriangulation.triangulate(width: 160,height: 160,pixels: pixels))
        XCTAssertGreaterThan(mesh.triangleCount,200)
        XCTAssertLessThanOrEqual(mesh.triangleCount,600)
        XCTAssertLessThanOrEqual(mesh.vertices.count,400)
        XCTAssertGreaterThan(mesh.outline.count,12)
        for point in centroids(mesh) {
            XCTAssertLessThanOrEqual(hypot(point.x-80,point.y-80),70)
            XCTAssertEqual(pixels[Int(point.y)*160+Int(point.x)],255)
        }
        // Snapped boundary vertices really reach the outline, instead of stopping a cell short.
        XCTAssertTrue(mesh.vertices.contains { p in
            mesh.outline.indices.contains { i in
                ContourGeometry.segmentDistance(p,mesh.outline[i],mesh.outline[(i+1)%mesh.outline.count]) < 0.00001
            }
        })
    }

    func testEmptyAndInvalidMasks() {
        XCTAssertEqual(MeshTriangulation.triangulate(width: 20,height: 20,pixels: Array(repeating: 0,count: 400)),.empty)
        XCTAssertEqual(MeshTriangulation.triangulate(width: 0,height: 0,pixels: []),.empty)
        XCTAssertEqual(MeshTriangulation.triangulate(width: -1,height: 4,pixels: []),.empty)
        XCTAssertEqual(MeshTriangulation.triangulate(width: 100,height: 100,pixels: [255]),.empty)
        XCTAssertEqual(MeshTriangulation.triangulate(polygons: []),.empty)
        XCTAssertEqual(MeshTriangulation.triangulate(polygons: [[CGPoint(x: CGFloat.nan,y: 1),.zero,CGPoint(x: 2,y: 3)]]),.empty)
    }

    func testDisconnectedComponentsAndHole() {
        let pixels = bitmap(180,100) { x,y in
            (hypot(x-50,y-50) <= 40 && hypot(x-50,y-50) >= 19) || (x > 110 && x < 170 && y > 20 && y < 80)
        }
        let mesh = MeshTriangulation.triangulate(width: 180,height: 100,pixels: pixels)
        XCTAssertEqual(mesh.outlines.count,3)
        for p in centroids(mesh) { XCTAssertEqual(pixels[Int(p.y)*180+Int(p.x)],255) }
        XCTAssertTrue(centroids(mesh).contains { $0.x > 110 })
        XCTAssertTrue(centroids(mesh).contains { $0.x < 90 })
    }

    func testConcavePolygonAndBudgetCoarsening() {
        let u: [CGPoint] = [.init(x: 0,y: 0),.init(x: 30,y: 0),.init(x: 30,y: 70),
                            .init(x: 70,y: 70),.init(x: 70,y: 0),.init(x: 100,y: 0),
                            .init(x: 100,y: 100),.init(x: 0,y: 100)]
        let mesh = MeshTriangulation.triangulate(polygons: [u],configuration: .init(cellFraction: 0.005,maximumTriangles: 150))
        XCTAssertLessThanOrEqual(mesh.triangleCount,150)
        XCTAssertGreaterThan(mesh.triangleCount,30)
        for p in centroids(mesh) { XCTAssertTrue(p.x <= 30 || p.x >= 70 || p.y >= 70) }
        XCTAssertTrue(mesh.vertices.contains { $0.y == 100 })
    }

    func testPolygonHoleAndDiagonalPixelContact() {
        let outer: [CGPoint] = [.zero,.init(x: 100,y: 0),.init(x: 100,y: 100),.init(x: 0,y: 100)]
        let hole: [CGPoint] = [.init(x: 30,y: 30),.init(x: 70,y: 30),.init(x: 70,y: 70),.init(x: 30,y: 70)]
        let mesh = MeshTriangulation.triangulate(polygons: [outer,hole])
        for p in centroids(mesh) { XCTAssertFalse(p.x > 30 && p.x < 70 && p.y > 30 && p.y < 70) }
        let diagonal = MeshTriangulation.triangulate(width: 2,height: 2,pixels: [255,0,0,255])
        XCTAssertEqual(diagonal.outlines.count,2)
    }

    func testSubCellHoleCannotBeCoveredByATriangle() {
        let outer: [CGPoint] = [.zero,.init(x: 100,y: 0),.init(x: 100,y: 100),.init(x: 0,y: 100)]
        let tinyHole: [CGPoint] = [.init(x: 1,y: 1),.init(x: 1.4,y: 1),.init(x: 1.4,y: 1.4),.init(x: 1,y: 1.4)]
        let mesh = MeshTriangulation.triangulate(polygons: [outer,tinyHole])
        let holeCenter = CGPoint(x: 1.2,y: 1.2)
        func side(_ p: CGPoint,_ a: CGPoint,_ b: CGPoint) -> CGFloat {
            (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
        }
        for i in stride(from: 0,to: mesh.triangleIndices.count,by: 3) {
            let t = mesh.triangleIndices[i..<i+3].map { mesh.vertices[$0] }
            XCTAssertFalse(side(holeCenter,t[0],t[1]) > 0 && side(holeCenter,t[1],t[2]) > 0
                           && side(holeCenter,t[2],t[0]) > 0)
        }
        XCTAssertEqual(MeshTriangulation.triangulate(polygons: [outer],configuration: .init(maximumTriangles: 1)),.empty)
    }

    func testGridConstructionPerformance() {
        let polygon: [CGPoint] = [.zero,.init(x: 512,y: 0),.init(x: 512,y: 768),.init(x: 0,y: 768)]
        var samples: [Double] = []
        var count = 0
        for _ in 0..<21 {
            let start = CFAbsoluteTimeGetCurrent()
            let mesh = MeshTriangulation.triangulate(polygons: [polygon])
            samples.append((CFAbsoluteTimeGetCurrent()-start)*1000)
            count = mesh.triangleCount
        }
        let median = samples.dropFirst().sorted()[10]
        print("MeshWrap grid: \(count) triangles, median \(median) ms (20 warm builds)")
        XCTAssertGreaterThan(count,500)
        XCTAssertLessThanOrEqual(count,600)
        XCTAssertLessThanOrEqual(median,5,"Grid construction budget")
    }
}
