import XCTest
@testable import TidalDrift
import CoreGraphics

/// The aspect fit decides both where the video is drawn and where a remote
/// click lands. When those two used separate implementations they drifted apart
/// after a resize or a host resolution change and every click landed offset, so
/// this pins the shared definition down.
final class VideoFitTests: XCTestCase {

    func test_matchingAspect_fillsView() {
        let rect = MetalRenderer.aspectFitRect(
            source: CGSize(width: 2560, height: 1440),
            in: CGSize(width: 1280, height: 720))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1280, height: 720))
    }

    func test_sourceWiderThanView_letterboxes() {
        // 16:9 source in a 4:3 view: bars top and bottom, full width.
        let rect = MetalRenderer.aspectFitRect(
            source: CGSize(width: 1920, height: 1080),
            in: CGSize(width: 800, height: 600))
        XCTAssertEqual(rect.width, 800, accuracy: 0.001)
        XCTAssertEqual(rect.height, 450, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 75, accuracy: 0.001)
    }

    func test_sourceTallerThanView_pillarboxes() {
        // A portrait window streamed into a landscape viewer.
        let rect = MetalRenderer.aspectFitRect(
            source: CGSize(width: 600, height: 900),
            in: CGSize(width: 1000, height: 600))
        XCTAssertEqual(rect.width, 400, accuracy: 0.001)
        XCTAssertEqual(rect.height, 600, accuracy: 0.001)
        XCTAssertEqual(rect.minX, 300, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 0, accuracy: 0.001)
    }

    func test_noSource_fillsView() {
        // Before the first frame there is nothing to fit; input must still map
        // somewhere sane rather than dividing by zero.
        let rect = MetalRenderer.aspectFitRect(
            source: .zero, in: CGSize(width: 640, height: 480))
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 640, height: 480))
    }

    func test_rectIsAlwaysCenteredAndContained() {
        let view = CGSize(width: 1440, height: 900)
        for source in [CGSize(width: 3840, height: 2160),
                       CGSize(width: 1024, height: 768),
                       CGSize(width: 500, height: 1200),
                       CGSize(width: 1440, height: 900)] {
            let rect = MetalRenderer.aspectFitRect(source: source, in: view)
            XCTAssertLessThanOrEqual(rect.width, view.width + 0.001, "\(source) overflows width")
            XCTAssertLessThanOrEqual(rect.height, view.height + 0.001, "\(source) overflows height")
            XCTAssertEqual(rect.midX, view.width / 2, accuracy: 0.001, "\(source) not centered")
            XCTAssertEqual(rect.midY, view.height / 2, accuracy: 0.001, "\(source) not centered")
            XCTAssertEqual(rect.width / rect.height,
                           source.width / source.height,
                           accuracy: 0.001,
                           "\(source) aspect not preserved")
        }
    }

    /// The center of a letterboxed video must normalize to the center of the
    /// remote screen, not the center of the view. This is the arithmetic the
    /// mouse path runs, and getting it wrong is the offset users see.
    func test_centerOfVideoNormalizesToRemoteCenter() {
        let view = CGSize(width: 800, height: 600)
        let rect = MetalRenderer.aspectFitRect(
            source: CGSize(width: 1920, height: 1080), in: view)
        let point = CGPoint(x: view.width / 2, y: view.height / 2)
        let relativeX = (point.x - rect.minX) / rect.width
        let relativeY = (point.y - rect.minY) / rect.height
        XCTAssertEqual(relativeX, 0.5, accuracy: 0.001)
        XCTAssertEqual(relativeY, 0.5, accuracy: 0.001)
    }

    /// A click in the letterbox bar is outside the video, so it must clamp to
    /// the edge rather than run off the remote screen.
    func test_pointInLetterboxBarClampsToEdge() {
        let view = CGSize(width: 800, height: 600)
        let rect = MetalRenderer.aspectFitRect(
            source: CGSize(width: 1920, height: 1080), in: view)
        let inTopBar = CGPoint(x: 400, y: 590)
        let raw = (inTopBar.y - rect.minY) / rect.height
        XCTAssertGreaterThan(raw, 1.0)
        XCTAssertEqual(min(max(raw, 0), 1), 1.0, accuracy: 0.001)
    }
}
