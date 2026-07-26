import Foundation
import AppKit
import CoreGraphics

// MARK: - Streamed window geometry tracking
//
// Split from HostSession.swift for file size. While a window or app is being
// streamed, poll the target window's Quartz bounds and react to the three ways
// it can drift out from under a live stream:
//
//   moved   -> re-point input mapping, no stream disruption
//   resized -> rebuild capture at the new size (debounced)
//   gone    -> redirect to the owning app, or the full display
//
// Full-display capture needs none of this: its bounds are either nil (live
// main-display lookup at injection time) or refreshed by the display-change
// observer, so the timer is not armed for that target.

extension HostSession {

    /// Arm tracking for the capture that just started. Safe to call for any
    /// target; a no-op unless the active capture is bound to a window.
    func startWindowTracking() {
        let windowID = captureManager.capturedWindowID
        let bounds = captureManager.captureBounds
        windowTrackQueue.async { [weak self] in
            guard let self else { return }
            self.windowTrackTimer?.cancel()
            self.windowTrackTimer = nil
            self.windowResizeRebuildWorkItem?.cancel()
            self.windowResizeRebuildWorkItem = nil
            self.trackedWindowMisses = 0
            self.trackedWindowBounds = bounds
            guard windowID != nil else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.windowTrackQueue)
            timer.schedule(deadline: .now() + Self.windowTrackInterval,
                           repeating: Self.windowTrackInterval)
            timer.setEventHandler { [weak self] in
                self?.checkTrackedWindow()
            }
            timer.resume()
            self.windowTrackTimer = timer
        }
    }

    func stopWindowTracking() {
        windowTrackQueue.async { [weak self] in
            guard let self else { return }
            self.windowTrackTimer?.cancel()
            self.windowTrackTimer = nil
            self.windowResizeRebuildWorkItem?.cancel()
            self.windowResizeRebuildWorkItem = nil
            self.trackedWindowBounds = nil
            self.trackedWindowMisses = 0
        }
    }

    /// One poll tick. Runs on `windowTrackQueue`, which owns all tracking state.
    private func checkTrackedWindow() {
        guard isRunning, hasActiveClient, isCaptureActive else { return }
        guard let windowID = captureManager.capturedWindowID else { return }

        guard let bounds = ScreenCaptureManager.quartzWindowBounds(windowID) else {
            // A window drops out of the window list for a beat while it
            // animates into full screen or between spaces, so only treat it as
            // gone after a few consecutive misses.
            trackedWindowMisses += 1
            if trackedWindowMisses >= 3 {
                handleTrackedWindowLost(windowID)
            }
            return
        }
        trackedWindowMisses = 0

        guard let previous = trackedWindowBounds else {
            trackedWindowBounds = bounds
            return
        }
        trackedWindowBounds = bounds

        let eps = Self.windowMoveEpsilon
        let resized = abs(bounds.width - previous.width) > eps
            || abs(bounds.height - previous.height) > eps
        let moved = abs(bounds.minX - previous.minX) > eps
            || abs(bounds.minY - previous.minY) > eps
        guard resized || moved else { return }

        // Re-point input either way: during a drag-resize this keeps clicks
        // close to the cursor until the debounced rebuild lands.
        captureManager.refreshCaptureBounds(bounds)
        inputInjector.captureBounds = bounds

        if resized {
            scheduleCaptureRebuildForResize(bounds)
        } else {
            logger.debug("🪟 Streamed window moved to \(NSStringFromRect(bounds)) — input bounds refreshed")
        }
    }

    /// The stream's pixel dimensions are fixed at creation, so a resized window
    /// needs a new stream. Debounced: a drag-resize reports a new size every
    /// tick and each rebuild costs a keyframe.
    private func scheduleCaptureRebuildForResize(_ bounds: CGRect) {
        windowResizeRebuildWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRunning, self.hasActiveClient, self.isCaptureActive else { return }
            self.logger.info("🪟 Streamed window resized to \(Int(bounds.width))x\(Int(bounds.height)) — rebuilding capture")
            // A user resizing a window is expected, not a failure; keep it out
            // of the restart budget that guards a genuinely broken capture.
            self.resetCaptureRestartAttempts()
            Task { [weak self] in
                guard let self else { return }
                await self.retarget(to: self.captureTarget)
            }
        }
        windowResizeRebuildWorkItem = work
        windowTrackQueue.asyncAfter(deadline: .now() + Self.windowResizeDebounce, execute: work)
    }

    /// The streamed window no longer exists. An app that goes full screen
    /// destroys its windowed window and creates a new one, so a pinned window
    /// ID would otherwise leave the viewer frozen on a dead target while the
    /// stall nudge retried the same missing ID forever.
    private func handleTrackedWindowLost(_ windowID: CGWindowID) {
        windowTrackTimer?.cancel()
        windowTrackTimer = nil

        if case .window(let id, _) = captureTarget, id != windowID { return }
        guard let fallback = windowLossFallback(afterStartFailure: false) else { return }
        logger.warning("🪟 Streamed window \(windowID) disappeared — falling back to \(fallback.label)")
        applyFallback(fallback)
    }

    /// Recovery for a capture that could not start because its target is gone.
    /// Without this the client's stall nudge re-drives `beginCaptureForClient`
    /// against the same missing window forever and the viewer never recovers.
    func recoverFromCaptureStartFailure(_ error: Error) {
        guard let windowError = error as? WindowCaptureError else { return }
        switch windowError {
        case .windowNotFound, .appNotFound:
            break
        case .capturePermissionDenied:
            return
        }
        guard let fallback = windowLossFallback(afterStartFailure: true) else { return }
        logger.warning("🪟 Capture target is gone — falling back to \(fallback.label)")
        applyFallback(fallback)
    }

    /// Where to send the stream when the current window target is no longer
    /// capturable. A pinned window ID redirects to the owning app, which picks
    /// up whatever window the app has now (the new one it created on going full
    /// screen, typically). App capture re-picks its largest window on restart,
    /// so rebuilding the same target is its own recovery, but only when the
    /// previous attempt had not already failed to start: retargeting to an app
    /// that cannot start would retry itself forever, so that case drops
    /// straight to the display.
    private func windowLossFallback(afterStartFailure: Bool) -> (target: HostCaptureTarget, label: String)? {
        let desktop: (HostCaptureTarget, String) = (.fullDisplay, "Entire Desktop")
        switch captureTarget {
        case .fullDisplay:
            return nil
        case .app(let pid, let name):
            guard !afterStartFailure, NSRunningApplication(processIdentifier: pid) != nil else {
                return desktop
            }
            return (.app(pid, name: name), name)
        case .window(_, let title):
            guard let pid = targetPID, NSRunningApplication(processIdentifier: pid) != nil else {
                return desktop
            }
            return (.app(pid, name: title), title)
        }
    }

    private func applyFallback(_ fallback: (target: HostCaptureTarget, label: String)) {
        Task { [weak self] in
            guard let self else { return }
            self.resetCaptureRestartAttempts()
            await self.retarget(to: fallback.target)
            self.onClientRetarget?(fallback.target, fallback.label)
        }
    }
}
