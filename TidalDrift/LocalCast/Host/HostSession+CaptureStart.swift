import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

// MARK: - Capture-target resolution and start
//
// Split from HostSession.swift for file size; these resolve the capture
// target (display, window, or app), configure the encoder, and start the
// SCStream. Called from beginCaptureForClient and the recovery paths, always
// inside a CaptureTransitionQueue operation.

extension HostSession {

    /// Displays ScreenCaptureKit can actually deliver frames from. A
    /// clamshelled built-in panel either vanishes from the list or lingers
    /// as an inactive/asleep entry that produces no frames; filter both out
    /// so the virtual-display fallback engages instead of a silent stall.
    static func usableDisplays(in content: SCShareableContent) -> [SCDisplay] {
        content.displays.filter {
            CGDisplayIsActive($0.displayID) != 0 && CGDisplayIsAsleep($0.displayID) == 0
        }
    }

    /// Update the input injector with the current capture bounds
    func updateInputBounds() {
        inputInjector.captureBounds = captureManager.captureBounds

        if let bounds = captureManager.captureBounds {
            logger.info("🎯 Input bounds set to: \(NSStringFromRect(bounds))")
        } else {
            logger.info("🎯 Input bounds set to full screen")
        }
    }

    /// Start full display capture (original behavior)
    func startFullDisplayCapture() async throws {
        targetPID = nil  // No window to resize in full display mode

        // Resolve the display from what ScreenCaptureKit can actually see.
        // CGMainDisplayID() returns a stale or detached ID while the lid is
        // closed or immediately after a network wake, and hardcoding it
        // failed lid-closed sessions with "Display 1 not found in available
        // displays" even when another display (external, or a virtual one)
        // was capturable. Prefer the main display when present, otherwise
        // capture the first usable one.
        var content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var usable = Self.usableDisplays(in: content)

        // Lid closed with no external monitor: the built-in panel drops out
        // of the display list entirely and there is nothing to capture.
        // Create a virtual display (the Jump Desktop / Splashtop approach)
        // and stream that. Retried once because early macOS 14 builds
        // transiently rejected creation while zero physical displays were
        // attached.
        if usable.isEmpty {
            logger.warning("No capturable display (lid closed / headless) — creating a virtual display")
            for attempt in 1...2 {
                guard virtualDisplay.create() != nil else { break }
                // WindowServer registration is asynchronous.
                try? await Task.sleep(nanoseconds: 700_000_000)
                content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                usable = Self.usableDisplays(in: content)
                if !usable.isEmpty { break }
                virtualDisplay.destroy()
                logger.warning("Virtual display did not register with ScreenCaptureKit (attempt \(attempt))")
            }
        }

        let mainID = CGMainDisplayID()
        guard let display = usable.first(where: { $0.displayID == mainID }) ?? usable.first else {
            logger.error("No capturable display and virtual display unavailable")
            throw LocalCastError.noDisplayAvailable
        }
        let displayID = display.displayID
        if displayID != mainID {
            logger.warning("Main display \(mainID) not capturable — falling back to display \(displayID) (\(display.width)x\(display.height) points)")
        } else {
            logger.info("Using display ID: \(displayID)")
        }

        // Get display mode for native resolution info. Fall back to the
        // SCDisplay point size (better than 0x0) if Core Graphics has no mode
        // for the resolved display.
        let mode = CGDisplayCopyDisplayMode(displayID)
        var nativeWidth = mode?.pixelWidth ?? CGDisplayPixelsWide(displayID)
        var nativeHeight = mode?.pixelHeight ?? CGDisplayPixelsHigh(displayID)
        if nativeWidth == 0 || nativeHeight == 0 {
            nativeWidth = display.width
            nativeHeight = display.height
        }

        // Cap resolution based on quality preset (ultra=3840, high=2560, etc.),
        // further reduced by any transport-capacity cap so keyframes stay
        // deliverable over a non-jumbo link.
        let maxDimension = effectiveMaxCaptureDimension
        let scale: Double
        if nativeWidth > maxDimension || nativeHeight > maxDimension {
            scale = Double(maxDimension) / Double(max(nativeWidth, nativeHeight))
        } else {
            scale = 1.0
        }

        // Round to even numbers (required for video encoding)
        let width = Int(Double(nativeWidth) * scale) & ~1
        let height = Int(Double(nativeHeight) * scale) & ~1

        logger.info("🚀 LocalCast: Capturing at \(width)x\(height) (native: \(nativeWidth)x\(nativeHeight), scale: \(String(format: "%.2f", scale)))")

        encoder.setup(
            width: width,
            height: height,
            codec: configuration.codec,
            bitrateMbps: effectiveBitrateMbps,
            fps: configuration.targetFrameRate,
            quality: configuration.encoderQuality
        )
        logger.info("✅ Video encoder configured: \(self.configuration.codec.rawValue), \(self.effectiveBitrateMbps)Mbps, \(self.configuration.targetFrameRate)fps, quality=\(self.configuration.encoderQuality)")

        try await captureManager.startCapture(
            displayID: displayID,
            width: width,
            height: height,
            frameRate: configuration.targetFrameRate
        )
    }

    /// Start window-specific capture
    func startWindowCapture(windowID: CGWindowID) async throws {
        // Look up the owning PID so we can resize the window later via Accessibility
        if let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
           let info = infoList.first,
           let pid = info[kCGWindowOwnerPID as String] as? pid_t {
            targetPID = pid
            logger.info("📐 Stored target PID \(pid) for window resize")
        }

        // Pre-create encoder with placeholder dimensions so the very first
        // frames don't get silently dropped. The encoder auto-reconfigures
        // when it receives frames at the actual Retina capture resolution.
        encoder.setup(
            width: 1920,
            height: 1080,
            codec: configuration.codec,
            bitrateMbps: effectiveBitrateMbps,
            fps: configuration.targetFrameRate,
            quality: configuration.encoderQuality
        )
        encoder.forceKeyFrame()

        try await captureManager.startWindowCapture(
            windowID: windowID,
            frameRate: configuration.targetFrameRate,
            maxDimension: effectiveMaxCaptureDimension
        )
    }

    /// Start app-specific capture
    func startAppCapture(processID: pid_t) async throws {
        targetPID = processID

        // Pre-create encoder with placeholder dimensions (auto-reconfigures
        // to actual Retina resolution on first frame).
        encoder.setup(
            width: 1920,
            height: 1080,
            codec: configuration.codec,
            bitrateMbps: effectiveBitrateMbps,
            fps: configuration.targetFrameRate,
            quality: configuration.encoderQuality
        )
        encoder.forceKeyFrame()

        try await captureManager.startAppCapture(
            processID: processID,
            frameRate: configuration.targetFrameRate,
            maxDimension: effectiveMaxCaptureDimension
        )
    }
}
