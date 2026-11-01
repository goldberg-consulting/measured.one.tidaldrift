import Foundation

/// Opt-in sender tuning. Stored separately from quality: a pacing limit controls
/// delivery, not the encoder's requested bitrate. Old configuration files omit it.
struct NetworkTuning: Codable, Equatable {
    var enabled = false
    var adaptive = true
    var rateMbps = 500
    var burstKB = 16
    var diagnostics = false
    var queueMilliseconds = 100

    var validated: Self {
        var value = self
        value.rateMbps = min(10_000, max(25, rateMbps))
        value.burstKB = min(64, max(4, burstKB))
        value.queueMilliseconds = min(500, max(50, queueMilliseconds))
        return value
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(enabled: defaults.bool(forKey: "localCastNetworkTuning"),
             adaptive: defaults.object(forKey: "localCastNetworkAdaptive") as? Bool ?? true,
             rateMbps: defaults.object(forKey: "localCastNetworkRate") as? Int ?? 500,
             burstKB: defaults.object(forKey: "localCastNetworkBurst") as? Int ?? 16,
             diagnostics: defaults.bool(forKey: "localCastNetworkDiagnostics"),
             queueMilliseconds: defaults.object(forKey: "localCastNetworkQueue") as? Int ?? 100).validated
    }
}

/// Pure pacing policy, shared by every frame on a connection. No accumulated
/// credits after a stall: waking late must never trigger a catch-up flood.
struct MediaPacingBudget {
    let settings: NetworkTuning
    private(set) var scale = 1.0
    private(set) var nextSendTime = 0.0
    private var cleanTicks = 0

    init(settings: NetworkTuning) { self.settings = settings.validated }
    var rateMbps: Double { Double(settings.rateMbps) * scale }
    var burstBytes: Int { settings.burstKB * 1000 }
    func delay(at now: Double) -> Double { max(0, nextSendTime - now) }

    mutating func sent(bytes: Int, at now: Double) {
        nextSendTime = max(now, nextSendTime) + Double(bytes) * 8 / (rateMbps * 1_000_000)
    }

    mutating func feedback(incompleteFrames: Int) {
        guard settings.adaptive else { return }
        if incompleteFrames > 0 {
            cleanTicks = 0
            scale = max(0.25, scale * 0.85)
        } else {
            cleanTicks += 1
            if cleanTicks >= 3 {
                scale = min(1, scale + 0.05)
                cleanTicks = 0
            }
        }
    }
}
