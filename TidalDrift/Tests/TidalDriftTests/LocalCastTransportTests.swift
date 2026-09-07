import XCTest
@testable import TidalDrift

final class LocalCastTransportTests: XCTestCase {
    func test_fastLAN_whenPathMTUUnknown_keepsStandardDatagrams() {
        let transport = UDPTransport()
        let safeCeiling = transport.keyframeByteCeiling()
        transport.setFastLAN(true, jumbo: true)
        XCTAssertTrue(transport.isFastLAN)
        XCTAssertEqual(transport.keyframeByteCeiling(), safeCeiling)
        XCTAssertEqual(UDPTransport.payloadSize(fastLAN: true, jumbo: true, validatedPathMTU: 1500), 1400)
    }

    func test_jumbo_whenPathMTUValidated_requiresExplicitProfileAndRequest() {
        XCTAssertEqual(UDPTransport.payloadSize(fastLAN: true, jumbo: true, validatedPathMTU: 9000), 8900)
        XCTAssertEqual(UDPTransport.payloadSize(fastLAN: true, jumbo: false, validatedPathMTU: 9000), 1400)
        XCTAssertEqual(UDPTransport.payloadSize(fastLAN: false, jumbo: true, validatedPathMTU: 9000), 1400)
    }

    func test_packetParsing_whenTimestampNotFinite_rejectsPacket() {
        for timestamp in [Double.nan, .infinity, -.infinity] {
            let packet = LocalCastPacket(type: .heartbeat, sequenceNumber: 1, timestamp: timestamp, payload: Data())
            XCTAssertNil(LocalCastPacket.deserialize(packet.serialize()))
        }
    }
}
