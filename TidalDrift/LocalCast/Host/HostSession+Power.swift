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
        } else {
            logger.warning("🔋 Failed to hold network-client activity: \(result)")
        }
        logger.info("🔋 Sleep prevention ON (viewer connected, capture active)")
    }

    func endStreamActivity() {
        streamActivityLock.lock()
        defer { streamActivityLock.unlock() }
        if let activity = streamActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamActivity = nil
        }
        if networkClientAssertion != 0 {
            IOPMAssertionRelease(networkClientAssertion)
            networkClientAssertion = 0
        }
        logger.info("🔋 Sleep prevention OFF")
    }

    /// Declare remote user activity to request framebuffer and GPU availability.
    /// macOS may keep the physical display asleep or decline a wake request.
    /// Rate-limited internally; safe to call on every inbound client packet.
    func declareRemoteUserActivity(
        now: Date = Date(),
        declaration: (inout IOPMAssertionID) -> IOReturn = { assertionID in
            IOPMAssertionDeclareUserActivity(
                "TidalDrift LocalCast viewer session" as CFString,
                kIOPMUserActiveRemote,
                &assertionID
            )
        }
    ) {
        userActivityLock.lock()
        defer { userActivityLock.unlock() }
        guard now.timeIntervalSince(lastUserActivityDeclaration) >= Self.userActivityMinInterval else { return }
        // Failed requests retry promptly, without doing power-management IPC
        // for every mouse-movement packet when the system keeps rejecting them.
        guard now.timeIntervalSince(lastUserActivityAttempt) >= Self.userActivityRetryInterval else { return }
        lastUserActivityAttempt = now

        var id = userActivityAssertionID
        let result = declaration(&id)
        if result == kIOReturnSuccess {
            userActivityAssertionID = id
            // An early wake can reject this call while power services recover.
            // Retry after a second instead of silencing attempts for 30 s.
            lastUserActivityDeclaration = now
            logger.info("⏰ Declared remote user activity (graphics access requested)")
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
        lastUserActivityAttempt = .distantPast
    }
}
