import Foundation
import IOKit.pwr_mgt

// MARK: - Sleep prevention and wake promotion
//
// Split from HostSession.swift for file size; the stored assertion state
// lives on HostSession (extensions cannot add stored properties) and is
// documented there.

extension HostSession {

    func beginStreamActivity() {
        streamActivityLock.lock()
        defer { streamActivityLock.unlock() }
        guard streamActivity == nil else { return }
        // idleDisplaySleepDisabled matters as much as system sleep: when the
        // host's display sleeps, ScreenCaptureKit suspends frame delivery and
        // the viewer freezes even though the machine is awake and pongs keep
        // flowing (so no reconnect fires). Remote viewing generates no local
        // HID activity, so the display idle timer runs out mid-session.
        streamActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled, .suddenTerminationDisabled],
            reason: "LocalCast streaming to a connected viewer"
        )
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertNetworkClientActive as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "LocalCast streaming to a connected viewer" as CFString,
            &id
        )
        if result == kIOReturnSuccess {
            networkClientAssertion = id
        }
        logger.info("🔋 Sleep prevention ON (viewer connected, capture active)")
    }

    func endStreamActivity() {
        streamActivityLock.lock()
        defer { streamActivityLock.unlock() }
        guard let activity = streamActivity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        streamActivity = nil
        if networkClientAssertion != 0 {
            IOPMAssertionRelease(networkClientAssertion)
            networkClientAssertion = 0
        }
        logger.info("🔋 Sleep prevention OFF")
    }

    /// Declare remote user activity, promoting the system to full wake.
    /// Rate-limited internally; safe to call on every inbound client packet.
    func declareRemoteUserActivity() {
        userActivityLock.lock()
        defer { userActivityLock.unlock() }
        let now = Date()
        guard now.timeIntervalSince(lastUserActivityDeclaration) >= Self.userActivityMinInterval else { return }
        lastUserActivityDeclaration = now

        var id = userActivityAssertionID
        let result = IOPMAssertionDeclareUserActivity(
            "TidalDrift LocalCast viewer session" as CFString,
            kIOPMUserActiveRemote,
            &id
        )
        if result == kIOReturnSuccess {
            userActivityAssertionID = id
            logger.info("⏰ Declared remote user activity (full-wake promotion)")
        } else {
            logger.warning("⏰ IOPMAssertionDeclareUserActivity failed: \(result)")
        }
    }

    func releaseUserActivityAssertion() {
        userActivityLock.lock()
        defer { userActivityLock.unlock() }
        if userActivityAssertionID != 0 {
            IOPMAssertionRelease(userActivityAssertionID)
            userActivityAssertionID = 0
        }
        lastUserActivityDeclaration = .distantPast
    }
}
