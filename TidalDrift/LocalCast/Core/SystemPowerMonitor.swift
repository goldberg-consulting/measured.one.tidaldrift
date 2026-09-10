import Foundation
import IOKit
import IOKit.pwr_mgt

/// IOKit system-power observer for the LocalCast host lifecycle.
///
/// Neither this observer nor `NSWorkspace.didWakeNotification` guarantees a
/// notification for DarkWake. Apple DTS explains that limitation here:
/// https://developer.apple.com/forums/thread/770517
/// LocalCast also checks elapsed suspension time in its hosting watchdog so
/// network recovery does not depend on the system reaching full wake.
final class SystemPowerMonitor {
    /// IOKit power message constants. These are C macros built from
    /// `iokit_common_msg(...)` that the Swift importer does not surface.
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    /// Fired on `kIOMessageSystemHasPoweredOn` for a full wake, on the main queue.
    var onWake: (() -> Void)?

    /// Fired on `kIOMessageSystemWillSleep`, before the change is allowed.
    var onSleep: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0

    func start() {
        guard rootPort == 0 else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            let monitor = Unmanaged<SystemPowerMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(messageType: messageType, argument: argument)
        }, &notifier)

        guard rootPort != 0, let notifyPort else {
            rootPort = 0
            return
        }
        IONotificationPortSetDispatchQueue(notifyPort, DispatchQueue.main)
    }

    func stop() {
        guard rootPort != 0 else { return }
        if notifier != 0 {
            IODeregisterForSystemPower(&notifier)
            notifier = 0
        }
        IOServiceClose(rootPort)
        rootPort = 0
        if let notifyPort {
            IONotificationPortDestroy(notifyPort)
            self.notifyPort = nil
        }
    }

    deinit {
        stop()
    }

    private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.messageSystemWillSleep:
            onSleep?()
            // Sleep is blocked (up to 30 s) until every registrant answers.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.messageCanSystemSleep:
            // Never veto idle sleep; the host relies on assertions instead.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.messageSystemHasPoweredOn:
            onWake?()
        default:
            break
        }
    }
}

/// Detects system suspension without assuming DarkWake has a public notification.
/// Accessed by LocalCastService on the main actor; samples are injectable for tests.
struct SystemResumeDetector {
    struct Sample {
        let continuousSeconds: TimeInterval
        let awakeSeconds: TimeInterval

        static func now() -> Sample {
            // Both raw clocks avoid wall-clock and frequency adjustments.
            // CLOCK_UPTIME_RAW pauses during sleep; CLOCK_MONOTONIC_RAW does not.
            Sample(
                continuousSeconds: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000,
                awakeSeconds: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
            )
        }
    }

    private var previousSample: Sample?
    private var recoveredSinceLastSleep = false
    private static let minimumSuspensionSeconds: TimeInterval = 1

    /// Refresh the watchdog baseline when hosting starts or its timer is replaced.
    /// Keep recovery state so a late full-wake callback cannot restart a
    /// listener that the watchdog just rebuilt.
    mutating func resetBaseline(at sample: Sample = .now()) {
        previousSample = sample
    }

    mutating func shouldRecover(at sample: Sample = .now(), notified: Bool = false) -> Bool {
        let suspended: Bool
        if let previousSample {
            let elapsed = sample.continuousSeconds - previousSample.continuousSeconds
            let awake = sample.awakeSeconds - previousSample.awakeSeconds
            suspended = elapsed >= 0 && awake >= 0
                && elapsed - awake >= Self.minimumSuspensionSeconds
        } else {
            suspended = false
        }
        previousSample = sample
        guard suspended || notified else { return false }

        // DarkWake can become full wake much later without another sleep.
        // Only a newly observed suspension re-arms recovery for that cycle.
        if suspended { recoveredSinceLastSleep = false }
        guard !recoveredSinceLastSleep else { return false }
        recoveredSinceLastSleep = true
        return true
    }
}
