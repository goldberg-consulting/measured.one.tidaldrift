import XCTest
@testable import TidalDrift

final class LocalCastDropCoordinatesTests: XCTestCase {
    func testDropUsesVideoOriginAndScale() throws {
        let point = try XCTUnwrap(LocalCastDropCoordinates.normalized(
            CGPoint(x: 300, y: 150),
            videoRect: CGRect(x: 100, y: 50, width: 800, height: 400), flipped: true))
        XCTAssertEqual(point.x, 0.25, accuracy: 0.0001)
        XCTAssertEqual(point.y, 0.25, accuracy: 0.0001)
    }

    func testUnflippedViewConvertsToRemoteTopOrigin() throws {
        let point = try XCTUnwrap(LocalCastDropCoordinates.normalized(
            CGPoint(x: 300, y: 150),
            videoRect: CGRect(x: 100, y: 50, width: 800, height: 400), flipped: false))
        XCTAssertEqual(point.y, 0.75, accuracy: 0.0001)
    }

    func testLetterboxAndInvalidGeometryRejectDrops() {
        let rect = CGRect(x: 100, y: 50, width: 800, height: 400)
        XCTAssertNil(LocalCastDropCoordinates.normalized(CGPoint(x: 50, y: 100), videoRect: rect, flipped: true))
        XCTAssertNil(LocalCastDropCoordinates.normalized(CGPoint(x: 300, y: .nan), videoRect: rect, flipped: true))
        XCTAssertNil(LocalCastDropCoordinates.normalized(.zero, videoRect: .zero, flipped: true))
    }
}
