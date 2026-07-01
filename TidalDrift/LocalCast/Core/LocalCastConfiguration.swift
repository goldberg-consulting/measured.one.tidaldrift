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

    enum LatencyMode: String, CaseIterable, Codable {
        case smooth
        case balanced
        case low

        var displayName: String {
            switch self {
            case .smooth: return "Smooth"
            case .balanced: return "Balanced"
            case .low: return "Low Latency"
            }
        }
    }

    /// Transport tuning profile. Resilient is the Wi-Fi tuned behavior (paced
    /// sends, tight keyframe cap, narrow reassembly window). Fast LAN drops the
    /// pacing and widens limits for a clean wired link. Auto starts resilient and
    /// promotes to Fast LAN when telemetry shows a low-RTT, loss-free path.
    enum TransportProfile: String, CaseIterable, Codable {
        case auto
        case resilient
        case fastLAN

        var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .resilient: return "Resilient (Wi-Fi)"
            case .fastLAN: return "Fast LAN"
            }
        }
    }
    
    var qualityPreset: QualityPreset = .ultra
    /// HEVC is the preferred Mac-to-Mac codec: it is hardware accelerated via
    /// VideoToolbox on modern Macs and uses fewer bits than H.264 at similar
    /// visual quality. The encoder falls back to H.264 if HEVC setup fails.
    var codec: Codec = .hevc
    var targetFrameRate: Int = 60
    var adaptiveQuality: Bool = false // Disable by default for "fastest pipe" on LAN
    var showLatencyOverlay: Bool = false
    /// When false (default), the host omits its cursor from the capture and the
    /// pointer the viewer sees is the local macOS cursor, so pointer motion
    /// never round-trips the capture/encode/decode pipeline. Enable to
    /// composite the host cursor into the stream (view-only sessions where the
    /// client follows the host user's pointer).
    var captureCursor: Bool = false
    var captureAudio: Bool = false  // Future

    /// User override for the capture's longest-edge dimension in pixels. 0 means
    /// "use the preset default". A value at/above the display's longest edge
    /// captures at native resolution, which is what large/ultrawide panels
    /// (e.g. 5120x1440) need. Aspect ratio is always preserved.
    var maxDimensionOverride: Int = 0

    /// Region-aware streaming (experimental): send only changed screen regions as
    /// lossless tiles, falling back to full-frame video on large changes.
    var regionAware: Bool = false

    /// Forward error correction over UDP video fragments. Adds parity packets so
    /// the client can recover a single lost fragment per FEC block without a
    /// retransmit. Host-side and safe to update live.
    var forwardErrorCorrection: Bool = false

    /// Client-side presentation policy. Low Latency (default) keeps the buffer
    /// minimal for the fastest cursor/control feedback; Balanced and Smooth add
    /// cushion for jittery links.
    var latencyMode: LatencyMode = .low

    /// Transport tuning profile. Defaults to Auto, which selects Fast LAN
    /// behavior on a measured fast wired link and Resilient otherwise.
    var transportProfile: TransportProfile = .auto
    
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

    /// Bitrate ceiling for the Fast LAN transport profile. A wired 10GbE link is
    /// not bandwidth constrained, so target well above the Wi-Fi tuned preset to
    /// keep the image sharp. Never lower than the preset's own bitrate. 250 Mbps
    /// HEVC at 5K/60 is visually near-lossless for desktop content; the hardware
    /// encoder and the (now off-callback-thread) transport both sustain it.
    var fastLANBitrateMbps: Int {
        max(bitrateMbps, 250)
    }
    
    /// Maximum capture dimension (longest edge). A user override (if set) wins;
    /// otherwise higher quality presets allow larger captures to preserve detail
    /// on high-DPI / large displays.
    var maxCaptureDimension: Int {
        if maxDimensionOverride > 0 { return maxDimensionOverride }
        switch qualityPreset {
        case .ultra: return 3840    // Up to 4K
        case .high: return 2560     // Up to 1440p
        case .balanced: return 1920 // 1080p
        case .low: return 1280      // 720p
        }
    }

    /// Resolution-cap choices for the streaming-resolution picker. `0` = Native
    /// (no cap, full panel resolution incl. ultrawide). Aspect ratio is always
    /// preserved; the value caps the longest edge.
    static let captureDimensionOptions: [(label: String, value: Int)] = [
        ("Native", 0),
        ("720p (1280)", 1280),
        ("1080p (1920)", 1920),
        ("1440p (2560)", 2560),
        ("4K (3840)", 3840),
        ("Ultrawide (5120)", 5120),
    ]
    
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
    private enum DefaultsKey {
        static let quality = "localCastLiveQuality"
        static let fps = "localCastLiveFpsOverride"
        static let bitrate = "localCastLiveBitrateOverride"
        static let encoderQuality = "localCastLiveEncoderQualityOverride"
        static let maxDimension = "localCastLiveMaxDimensionOverride"
    }
    
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
    
    /// Allowed bitrate choices (Mbps) for the stepper/picker. 200-400 are for
    /// wired multi-gig links (Fast LAN); Wi-Fi cannot sustain them.
    static let bitrateOptions: [Int] = [8, 15, 30, 50, 75, 100, 150, 200, 300, 400]
    
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

    /// Persist the live tuning values so a host restart (needed for codec,
    /// resolution, FEC, or region-aware changes) does not reset the slider back
    /// to the preset. This mirrors game-streaming clients: negotiated session
    /// parameters stay stable until the user changes them.
    func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(quality, forKey: DefaultsKey.quality)
        setOptional(fpsOverride, forKey: DefaultsKey.fps, defaults: defaults)
        setOptional(bitrateOverride, forKey: DefaultsKey.bitrate, defaults: defaults)
        if let encoderQualityOverride {
            defaults.set(Double(encoderQualityOverride), forKey: DefaultsKey.encoderQuality)
        } else {
            defaults.removeObject(forKey: DefaultsKey.encoderQuality)
        }
        setOptional(maxDimensionOverride, forKey: DefaultsKey.maxDimension, defaults: defaults)
    }

    /// Load live tuning values, if present. Returns true when a saved live tune
    /// was found; false means callers should sync from the quality preset.
    @discardableResult
    func loadFromDefaults() -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: DefaultsKey.quality) != nil else { return false }
        quality = defaults.double(forKey: DefaultsKey.quality)
        fpsOverride = optionalInt(DefaultsKey.fps, defaults: defaults)
        bitrateOverride = optionalInt(DefaultsKey.bitrate, defaults: defaults)
        if defaults.object(forKey: DefaultsKey.encoderQuality) != nil {
            encoderQualityOverride = Float(defaults.double(forKey: DefaultsKey.encoderQuality))
        } else {
            encoderQualityOverride = nil
        }
        maxDimensionOverride = optionalInt(DefaultsKey.maxDimension, defaults: defaults)
        return true
    }
    
    // MARK: - Interpolation helpers
    
    private static func interpolate(low: Int, high: Int, t: Double) -> Int {
        Int(Double(low) + Double(high - low) * t)
    }
    
    private static func interpolateDouble(low: Double, high: Double, t: Double) -> Double {
        low + (high - low) * t
    }

    private func setOptional(_ value: Int?, forKey key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func optionalInt(_ key: String, defaults: UserDefaults) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
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
