import Foundation

/// Validated values retained across capture rebuilds and loss/thermal adaptation.
struct StreamingParameters: Equatable, Sendable {
    let fps: Int
    let bitrateMbps: Int
    let quality: Float
    let keyframeInterval: Double
    let maxDimension: Int
    let hasDimensionOverride: Bool

    init(_ tuning: StreamingTuning) {
        fps = tuning.effectiveFps
        bitrateMbps = tuning.effectiveBitrateMbps
        quality = tuning.effectiveEncoderQuality
        keyframeInterval = tuning.effectiveKeyframeInterval
        maxDimension = tuning.effectiveMaxDimension
        hasDimensionOverride = tuning.maxDimensionOverride != nil
    }

    /// Explicit viewer tuning wins; otherwise the host's resolution policy applies.
    func captureDimension(configuration: LocalCastConfiguration) -> Int {
        if hasDimensionOverride || configuration.maxDimensionOverride == 0 { return maxDimension }
        return configuration.maxCaptureDimension
    }
}
