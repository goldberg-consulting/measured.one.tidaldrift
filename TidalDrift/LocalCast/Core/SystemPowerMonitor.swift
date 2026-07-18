import Foundation
import IOKit
import IOKit.pwr_mgt

/// IOKit system-power observer for the LocalCast host lifecycle.
///
/// `NSWorkspace.didWakeNotification` is only posted on a *full* wake. A
/// sleeping Mac woken over the network by the Bonjour sleep proxy (the
/// client's TCP-5900 knock) comes up in DarkWake, where that notification
/// never fires, so the host's listener-rebind never ran and a lid-closed
/// host stayed unreachable even though the machine itself was awake.
/// `IORegisterForSystemPower` delivers its power messages for every wake,
/// dark or full, which makes it the reliable rebind trigger.
final class SystemPowerMonitor {
    /// IOKit power message constants. These are C macros built from
    /// `iokit_common_msg(...)` that the Swift importer does not surface.
    private static let messageSystemWillSleep: UInt32 = 0xE000_0280
    private static let messageCanSystemSleep: UInt32 = 0xE000_0270
    private static let messageSystemWillPowerOn: UInt32 = 0xE000_0320
    private static let messageSystemHasPoweredOn: UInt32 = 0xE000_0300

    /// Fired on `kIOMessageSystemHasPoweredOn` for every wake, including
    /// DarkWake. Delivered on the main queue.
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
