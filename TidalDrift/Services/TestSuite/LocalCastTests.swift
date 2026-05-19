import Foundation
import CoreGraphics

extension TidalDriftTestRunner {
    
    func testStreamingTuningInterpolation() async -> (Bool, String) {
        let tuning = StreamingTuning()
        
        tuning.quality = 0.0
        let lowFps = tuning.effectiveFps
        let lowBitrate = tuning.effectiveBitrateMbps
        let lowDim = tuning.effectiveMaxDimension
        
        tuning.quality = 1.0
        let highFps = tuning.effectiveFps
        let highBitrate = tuning.effectiveBitrateMbps
        let highDim = tuning.effectiveMaxDimension
        
        guard highFps > lowFps else {
            return (false, "FPS did not increase: low=\(lowFps), high=\(highFps)")
        }
        guard highBitrate > lowBitrate else {
            return (false, "Bitrate did not increase: low=\(lowBitrate), high=\(highBitrate)")
        }
        guard highDim > lowDim else {
            return (false, "Dimension did not increase: low=\(lowDim), high=\(highDim)")
        }
        
        // Test clamping
        tuning.quality = -5.0
        guard tuning.quality >= 0.0 else {
            return (false, "Quality not clamped to 0.0: \(tuning.quality)")
        }
        tuning.quality = 99.0
        guard tuning.quality <= 1.0 else {
            return (false, "Quality not clamped to 1.0: \(tuning.quality)")
        }
        
        // Test overrides
        tuning.quality = 0.5
        tuning.fpsOverride = 90
        guard tuning.effectiveFps == 90 else {
            return (false, "FPS override not applied: expected 90, got \(tuning.effectiveFps)")
        }
        tuning.resetOverrides()
        guard tuning.effectiveFps != 90 else {
            return (false, "Override not cleared after reset")
        }
        
        return (true, "Tuning: low(\(lowFps)fps/\(lowBitrate)Mbps) -> high(\(highFps)fps/\(highBitrate)Mbps), clamping OK, overrides OK")
    }
    
    func testQualityPayloadCodable() async -> (Bool, String) {
        let payload = QualityUpdatePayload(
            quality: 0.73,
            fpsOverride: 60,
            bitrateOverride: nil,
            encoderQualityOverride: 0.85,
            maxDimensionOverride: 2560
        )
        
        guard let encoded = try? JSONEncoder().encode(payload) else {
            return (false, "Failed to encode QualityUpdatePayload")
        }
        guard let decoded = try? JSONDecoder().decode(QualityUpdatePayload.self, from: encoded) else {
            return (false, "Failed to decode QualityUpdatePayload")
        }
        
        guard decoded.quality == payload.quality,
              decoded.fpsOverride == payload.fpsOverride,
              decoded.bitrateOverride == payload.bitrateOverride,
              decoded.encoderQualityOverride == payload.encoderQualityOverride,
              decoded.maxDimensionOverride == payload.maxDimensionOverride else {
            return (false, "Decoded payload does not match original")
        }
        
        return (true, "QualityUpdatePayload encodes/decodes correctly (\(encoded.count) bytes)")
    }
    
    func testPacketProtocol() async -> (Bool, String) {
        let original = LocalCastPacket(
            type: .videoFrame,
            sequenceNumber: 42,
            timestamp: Date().timeIntervalSince1970,
            payload: Data(repeating: 0xAB, count: 100)
        )
        
        let serialized = original.serialize()
        guard !serialized.isEmpty else {
            return (false, "Packet serialization produced empty data")
        }
        
        guard let deserialized = LocalCastPacket.deserialize(serialized) else {
            return (false, "Packet deserialization returned nil")
        }
        
        guard deserialized.type == original.type,
              deserialized.sequenceNumber == original.sequenceNumber,
              deserialized.payload == original.payload else {
            return (false, "Deserialized packet does not match original")
        }
        
        // Test a representative set of packet types
        let testTypes: [LocalCastPacket.PacketType] = [
            .videoFrame, .heartbeat, .inputEvent, .stats,
            .keyframeRequest, .config, .appListRequest, .authRequest
        ]
        for pktType in testTypes {
            let pkt = LocalCastPacket(type: pktType, sequenceNumber: 1, timestamp: 0, payload: Data())
            let data = pkt.serialize()
            guard let back = LocalCastPacket.deserialize(data), back.type == pktType else {
                return (false, "Round-trip failed for packet type \(pktType.rawValue)")
            }
        }
        
        return (true, "Packet protocol: serialize/deserialize OK, \(testTypes.count) types verified, \(serialized.count)B wire format")
    }
    
    func testHostSessionLoopback() async -> (Bool, String) {
        guard CGPreflightScreenCaptureAccess() else {
            return (false, "Skipped — Screen Recording permission required")
        }
        
        do {
            let config = LocalCastConfiguration.default
            let session = HostSession(configuration: config, password: nil)
            try await session.start(target: .fullDisplay)
            
            await session.stop()
            return (true, "Host session started full-display capture and stopped cleanly")
        } catch {
            return (false, "Host session failed to start: \(error.localizedDescription)")
        }
    }
}
