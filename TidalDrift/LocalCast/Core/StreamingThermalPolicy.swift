import Foundation

/// Shed capture and encoding work before macOS reaches serious pressure.
/// Applied to requested quality, so a cap never raises the requested FPS.
struct StreamingThermalPolicy: Equatable {
    let frameRateCap: Int
    let bitrateScale: Double

    init(state: ProcessInfo.ThermalState, enabled: Bool) {
        switch enabled ? state : .nominal {
        case .fair:
            frameRateCap = 45
            bitrateScale = 0.75
        case .serious:
            frameRateCap = 30
            bitrateScale = 0.5
        case .critical:
            frameRateCap = 15
            bitrateScale = 0.25
        default:
            frameRateCap = .max
            bitrateScale = 1.0
        }
    }
}
