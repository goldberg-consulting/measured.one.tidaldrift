import Foundation
import Combine

struct LocalCastConfiguration: Codable {
    enum QualityPreset: String, CaseIterable, Codable {
        case ultra      // 100 Mbps, native resolution, 60fps
        case high       // 50 Mbps, native resolution, 60fps
        case balanced   // 30 Mbps, native resolution, 30fps
        case low        // 15 Mbps, 75% resolution, 30fps
    }
    
    enum Codec: String, CaseIterable, Codable {
        case h264       // Wider compatibility, faster encode
        case hevc       // Better compression, newer Macs only
    }
    
    var qualityPreset: QualityPreset = .ultra
    var codec: Codec = .h264  // Use H.264 for reliable NAL parsing (HEVC has different NAL format)
    var targetFrameRate: Int = 60
    var adaptiveQuality: Bool = false // Disable by default for "fastest pipe" on LAN
    var showLatencyOverlay: Bool = false
    var captureCursor: Bool = true
    var captureAudio: Bool = false  // Future
    
    // Security
    var requireAuthentication: Bool = true
    var inputRateLimit: Int = 120  // events per second, 0 = unlimited
    
    // Derived properties
    var bitrateMbps: Int {
        switch qualityPreset {
        case .ultra: return 100
        case .high: return 50
        case .balanced: return 30
        case .low: return 15
        }
    }
    
    var scaleFactor: CGFloat {
        qualityPreset == .low ? 0.75 : 1.0
    }
    
    /// Maximum capture dimension (longest edge). Higher quality presets allow
    /// larger captures to preserve detail on high-DPI / large displays.
    var maxCaptureDimension: Int {
        switch qualityPreset {
        case .ultra: return 3840    // Up to 4K
        case .high: return 2560     // Up to 1440p
        case .balanced: return 1920 // 1080p
        case .low: return 1280      // 720p
        }
    }
    
    /// Encoder quality hint passed to VTCompressionSession (0.0 = min, 1.0 = lossless).
    var encoderQuality: Float {
        switch qualityPreset {
        case .ultra: return 0.92
        case .high: return 0.80
        case .balanced: return 0.70
        case .low: return 0.55
        }
    }
    
    /// Preset choices for the input rate-limit picker in settings UI.
    static let inputRateLimitOptions: [Int] = [60, 120, 240, 500, 0]
    
    static let `default` = LocalCastConfiguration()
    
    /// UDP port for the LocalCast control channel (app list, focus, isolate, stream requests).
    /// Host listens here; client connects here. If your firewall blocks 5904, change this and ensure
    /// both host and client use the same port (e.g. via a build-time constant or settings).
    static let hostPort: UInt16 = 5904
}

// MARK: - Live Streaming Quality Tuning

/// Continuous, live-adjustable streaming parameters.
/// The master `quality` slider (0.0–1.0) smoothly interpolates all derived
/// values between the "low" and "ultra" extremes. Individual overrides let
/// power users fine-tune specific axes.
class StreamingTuning: ObservableObject {
    
    // MARK: - Master slider (0.0 = lowest, 1.0 = best)
    
    @Published var quality: Double = 1.0 {
        didSet {
            let clamped = quality.clamped(to: 0...1)
            if clamped != oldValue, clamped != quality { quality = clamped }
        }
    }
    
    // MARK: - Individual overrides (nil = derive from master slider)
    
    @Published var fpsOverride: Int?
    @Published var bitrateOverride: Int?          // Mbps
    @Published var encoderQualityOverride: Float?  // 0.0–1.0
    @Published var maxDimensionOverride: Int?
    
    // MARK: - Resolved (effective) values
    
    /// Effective FPS (override or interpolated from master slider).
    var effectiveFps: Int {
        if let fps = fpsOverride { return fps }
        return Self.interpolate(low: 15, high: 120, t: quality)
    }
    
    /// Effective bitrate in Mbps (override or interpolated).
    var effectiveBitrateMbps: Int {
        if let br = bitrateOverride { return br }
        return Self.interpolate(low: 8, high: 150, t: quality)
    }
    
    /// Effective encoder quality hint (override or interpolated).
    var effectiveEncoderQuality: Float {
        if let q = encoderQualityOverride { return q }
        return Float(Self.interpolateDouble(low: 0.40, high: 0.95, t: quality))
    }
    
    /// Effective max capture dimension (override or interpolated).
    var effectiveMaxDimension: Int {
        if let d = maxDimensionOverride { return d }
        return Self.interpolate(low: 1280, high: 3840, t: quality) & ~1
    }
    
    /// Effective keyframe interval in seconds. Higher quality = less frequent
    /// keyframes (fewer massive I-frames on the wire).
    var effectiveKeyframeInterval: Double {
        Self.interpolateDouble(low: 2.0, high: 5.0, t: quality)
    }
    
    // MARK: - Preset snap points
    
    static let presetValues: [(name: String, quality: Double)] = [
        ("Low",      0.10),
        ("Balanced", 0.40),
        ("High",     0.65),
        ("Ultra",    0.85),
        ("Extreme",  1.00),
    ]
    
    /// Allowed FPS choices for the stepper/picker.
    static let fpsOptions: [Int] = [15, 24, 30, 48, 60, 90, 120]
    
    /// Allowed bitrate choices (Mbps) for the stepper/picker.
    static let bitrateOptions: [Int] = [8, 15, 30, 50, 75, 100, 150]
    
    /// Allowed max-dimension choices for the picker.
    static let dimensionOptions: [Int] = [1280, 1920, 2560, 3840]
    
    /// Reset all overrides so everything derives from the master slider.
    func resetOverrides() {
        fpsOverride = nil
        bitrateOverride = nil
        encoderQualityOverride = nil
        maxDimensionOverride = nil
    }
    
    /// Snap the master slider to the nearest named preset.
    func snapToNearestPreset() {
        if let closest = Self.presetValues.min(by: { abs($0.quality - quality) < abs($1.quality - quality) }) {
            quality = closest.quality
        }
    }
    
    /// Populate from a `LocalCastConfiguration` (for initial sync).
    func syncFrom(_ config: LocalCastConfiguration) {
        switch config.qualityPreset {
        case .ultra:    quality = 0.85
        case .high:     quality = 0.65
        case .balanced: quality = 0.40
        case .low:      quality = 0.10
        }
        resetOverrides()
    }
    
    // MARK: - Wire payload for client → host sync
    
    func toPayload() -> QualityUpdatePayload {
        QualityUpdatePayload(
            quality: quality,
            fpsOverride: fpsOverride,
            bitrateOverride: bitrateOverride,
            encoderQualityOverride: encoderQualityOverride,
            maxDimensionOverride: maxDimensionOverride
        )
    }
    
    func apply(_ payload: QualityUpdatePayload) {
        quality = payload.quality
        fpsOverride = payload.fpsOverride
        bitrateOverride = payload.bitrateOverride
        encoderQualityOverride = payload.encoderQualityOverride
        maxDimensionOverride = payload.maxDimensionOverride
    }
    
    // MARK: - Interpolation helpers
    
    private static func interpolate(low: Int, high: Int, t: Double) -> Int {
        Int(Double(low) + Double(high - low) * t)
    }
    
    private static func interpolateDouble(low: Double, high: Double, t: Double) -> Double {
        low + (high - low) * t
    }
}

struct QualityUpdatePayload: Codable {
    let quality: Double
    let fpsOverride: Int?
    let bitrateOverride: Int?
    let encoderQualityOverride: Float?
    let maxDimensionOverride: Int?
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
