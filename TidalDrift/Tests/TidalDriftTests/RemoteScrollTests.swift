import XCTest
import CoreGraphics
@testable import TidalDrift

final class RemoteScrollTests: XCTestCase {
    func testScrollCarriesItsOwnHitPoint() throws {
        let packet = InputInjector.RemoteInput.scroll(
            deltaX: 2, deltaY: -4, precise: true, position: CGPoint(x: 0.25, y: 0.75)
        ).serialize()
        XCTAssertEqual(packet.count, 34)
        guard case .scroll(let dx, let dy, let precise, let position)? =
                InputInjector.RemoteInput.deserialize(packet) else {
            return XCTFail("Positioned scroll did not decode")
        }
        XCTAssertEqual(dx, 2)
        XCTAssertEqual(dy, -4)
        XCTAssertTrue(precise)
        XCTAssertEqual(position, CGPoint(x: 0.25, y: 0.75))
        var builder = RemoteScrollEventBuilder()
        let target = CGPoint(x: 420, y: 730)
        let event = try XCTUnwrap(builder.makeEvent(deltaX: dx, deltaY: dy, precise: precise, location: target))
        XCTAssertEqual(event.location, target, "Scroll must hit the streamed content, independent of the host cursor")
        XCTAssertEqual(event.type, .scrollWheel)
    }

    func testLegacyScrollPacketsRemainReadable() {
        let original = InputInjector.RemoteInput.scroll(deltaX: 0, deltaY: 3, precise: false).serialize()
        for count in [17, 18] {
            guard case .scroll(_, let dy, let precise, let position)? =
                    InputInjector.RemoteInput.deserialize(Data(original.prefix(count))) else {
                return XCTFail("Legacy scroll did not decode")
            }
            XCTAssertEqual(dy, 3)
            XCTAssertEqual(precise, count == 17)
            XCTAssertNil(position)
        }
    }

    func testTruncatedPositionAndNonfiniteInputAreRejected() {
        let packet = InputInjector.RemoteInput.scroll(
            deltaX: 0, deltaY: 1, precise: true, position: CGPoint(x: 0.5, y: 0.5)
        ).serialize()
        for count in 19..<34 {
            XCTAssertNil(InputInjector.RemoteInput.deserialize(Data(packet.prefix(count))))
        }
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(InputInjector.RemoteInput.deserialize(
                InputInjector.RemoteInput.scroll(deltaX: invalid, deltaY: 1, precise: true).serialize()))
        }
    }

    func testSmallWheelDeltasAccumulateInsteadOfDisappearing() throws {
        var builder = RemoteScrollEventBuilder()
        for _ in 0..<3 {
            XCTAssertNil(builder.makeEvent(deltaX: 0.25, deltaY: -0.25, precise: false, location: nil))
        }
        let event = try XCTUnwrap(builder.makeEvent(deltaX: 0.25, deltaY: -0.25, precise: false, location: nil))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
    }

    func testSmallTrackpadDeltasAccumulateAsPixels() throws {
        var builder = RemoteScrollEventBuilder()
        XCTAssertNil(builder.makeEvent(deltaX: 0, deltaY: 0.25, precise: true, location: nil))
        XCTAssertNil(builder.makeEvent(deltaX: 0, deltaY: 0.25, precise: true, location: nil))
        XCTAssertNil(builder.makeEvent(deltaX: 0, deltaY: 0.25, precise: true, location: nil))
        let event = try XCTUnwrap(builder.makeEvent(deltaX: 0, deltaY: 0.25, precise: true, location: nil))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 1)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
    }

    func testSwitchingUnitsDoesNotCarryPixelRemaindersIntoLines() {
        var builder = RemoteScrollEventBuilder()
        XCTAssertNil(builder.makeEvent(deltaX: 0, deltaY: 0.75, precise: true, location: nil))
        XCTAssertNil(builder.makeEvent(deltaX: 0, deltaY: 0.25, precise: false, location: nil))
    }

    func testInvalidAndExtremeDeltasCannotTrapIntegerConversion() throws {
        var builder = RemoteScrollEventBuilder()
        XCTAssertNil(builder.makeEvent(deltaX: .nan, deltaY: 1, precise: false, location: nil))
        XCTAssertNil(builder.makeEvent(deltaX: 1, deltaY: .infinity, precise: false, location: nil))
        let event = try XCTUnwrap(builder.makeEvent(
            deltaX: .greatestFiniteMagnitude, deltaY: -.greatestFiniteMagnitude, precise: false, location: nil))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis1), -10_000)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventDeltaAxis2), 10_000)
    }
}
