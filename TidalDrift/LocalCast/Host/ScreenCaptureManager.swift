import Foundation
import ScreenCaptureKit
import AppKit
import OSLog

protocol ScreenCaptureManagerDelegate: AnyObject {
    func screenCaptureManager(_ manager: ScreenCaptureManager, didOutput sampleBuffer: CMSampleBuffer)
    func screenCaptureManager(_ manager: ScreenCaptureManager, didFailWithError error: Error)
}

/// Capture mode for LocalCast streaming
enum CaptureMode {
    case fullDisplay(CGDirectDisplayID)
    case singleWindow(CGWindowID)
    case singleApp(pid_t)
}

/// Window capture specific errors
enum WindowCaptureError: LocalizedError {
    case windowNotFound
    case appNotFound
    case capturePermissionDenied
    
    var errorDescription: String? {
        switch self {
        case .windowNotFound:
            return "The specified window could not be found"
        case .appNotFound:
            return "The specified application could not be found"
        case .capturePermissionDenied:
            return "Screen capture permission is required"
        }
    }
}

class ScreenCaptureManager: NSObject, SCStreamOutput, SCStreamDelegate {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "ScreenCapture")
    
    weak var delegate: ScreenCaptureManagerDelegate?
    
    private var stream: SCStream?
    private let captureQueue = DispatchQueue(label: "com.tidaldrift.localcast.capture", qos: .userInteractive)

    /// Per-frame change description parsed from ScreenCaptureKit's frame info.
    /// `dirtyRects` are in the capture pixel-buffer coordinate space (top-left
    /// origin). `coverage` is the changed fraction of the frame. `isIdle` means
    /// the frame carried no new content (status != complete).
    struct FrameChangeInfo {
        let dirtyRects: [CGRect]
        let coverage: Double
        let isIdle: Bool
    }

    /// Change info for the most recent delivered sample buffer. Set immediately
    /// before the `didOutput` delegate call (single capture queue), so the
    /// delegate can read it synchronously for the same frame.
    private(set) var lastFrameChange: FrameChangeInfo?

    // Rolling coverage stats for Phase 0 instrumentation.
    private var statFrames = 0
    private var statCoverageSum = 0.0
    private var statIdle = 0
    private var statSmall = 0

    /// The configuration the active stream was created with. `updateConfiguration`
    /// replaces the *entire* configuration, so live updates must start from this
    /// (preserving width/height/pixelFormat/etc.) and change only what's needed.
    private var activeConfig: SCStreamConfiguration?
    
    deinit {
        if let stream = stream {
            stream.stopCapture { _ in }
        }
        stream = nil
    }
    
    /// Whether the host cursor is composited into captured frames. Off by
    /// default: the viewer's local cursor is the pointer, so pointer motion
    /// does not round-trip the streaming pipeline. Read at stream setup;
    /// `updateCursorCapture` applies changes to a live stream on macOS 14+.
    var captureCursor = false

    /// Whether the active session captures for the region-aware (tile) path,
    /// which copies tightly-packed 32BGRA sub-rects. When true the stream is
    /// captured as 32BGRA so `cropBGRA`/`TileCodec` keep working; when false
    /// (the default video path) the stream is captured as NV12 (4:2:0 biplanar,
    /// full range) so the IOSurface stays zero-copy into VideoToolbox and Metal
    /// with no BGRA<->NV12 conversions. Read at `startStream` time.
    var regionAwareCapture = false

    /// Current capture mode
    private(set) var captureMode: CaptureMode?
    
    /// The screen bounds of the captured content (for input coordinate mapping)
    /// For full display: the display bounds
    /// For window: the window's frame on screen
    /// For app: the bounding box of all app windows
    private(set) var captureBounds: CGRect?
    
    // MARK: - Full Display Capture
    
    func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int, frameRate: Int) async throws {
        logger.info("Requesting shareable content...")
        
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            logger.info("Got shareable content: \(content.displays.count) displays, \(content.windows.count) windows")
        } catch {
            logger.error("Failed to get shareable content (permission denied?): \(error.localizedDescription)")
            throw error
        }
        
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            logger.error("Display \(displayID) not found in available displays: \(content.displays.map { $0.displayID })")
            throw LocalCastError.noDisplayAvailable
        }
        
        logger.info("Found display: \(display.displayID) (\(display.width)x\(display.height))")
        
        let filter = SCContentFilter(display: display, excludingWindows: [])
        
        // Full display capture - bounds are the full display
        captureBounds = nil  // nil means full screen, use main display dimensions
        captureMode = .fullDisplay(displayID)
        try await startStream(with: filter, width: width, height: height, frameRate: frameRate, description: "display \(displayID)")
    }
    
    // MARK: - Single Window Capture
    
    /// Start capturing a specific window by its window ID
    func startWindowCapture(windowID: CGWindowID, frameRate: Int = 30, maxDimension: Int = 2560) async throws {
        logger.info("Starting window capture for windowID: \(windowID)")
        
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            logger.info("Got shareable content: \(content.windows.count) windows")
        } catch {
            logger.error("Failed to get shareable content: \(error.localizedDescription)")
            throw error
        }
        
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            logger.error("Window \(windowID) not found in available windows")
            throw WindowCaptureError.windowNotFound
        }
        
        logger.info("Found window: '\(window.title ?? "Untitled")' at frame \(NSStringFromRect(window.frame))")
        
        let filter = SCContentFilter(desktopIndependentWindow: window)
        
        // window.frame is in points. Multiply by backingScaleFactor to get
        // actual pixel dimensions on Retina displays (typically 2x).
        let retinaScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = window.frame.width * retinaScale
        let pixelHeight = window.frame.height * retinaScale
        
        let scale: Double
        if pixelWidth > CGFloat(maxDimension) || pixelHeight > CGFloat(maxDimension) {
            scale = Double(maxDimension) / Double(max(pixelWidth, pixelHeight))
        } else {
            scale = 1.0
        }
        
        // Round to even numbers (required for video encoding)
        let width = Int(pixelWidth * scale) & ~1
        let height = Int(pixelHeight * scale) & ~1
        
        // Store the window's on-screen bounds for input mapping. Prefer the
        // Quartz (top-left origin) bounds from CGWindowList, which match the
        // coordinate space CGEvent injection uses; SCWindow.frame can differ in
        // Y origin and throw remote clicks off when streaming a single window.
        let bounds = Self.quartzWindowBounds(windowID) ?? window.frame
        captureBounds = bounds
        captureMode = .singleWindow(windowID)
        
        logger.info("🪟 Window capture bounds (Quartz): \(NSStringFromRect(bounds)) [SCWindow.frame: \(NSStringFromRect(window.frame))]")
        try await startStream(with: filter, width: width, height: height, frameRate: frameRate, description: "window '\(window.title ?? "Untitled")'")
    }
    
    // MARK: - Single App Capture
    
    /// Start capturing a specific application by capturing its largest visible window.
    ///
    /// Uses `desktopIndependentWindow` (the same approach as single-window capture)
    /// instead of `display+including+sourceRect`. This guarantees the video output
    /// is perfectly cropped to the window content, and `captureBounds` (window.frame)
    /// maps directly to Quartz global coordinates for accurate cursor injection.
    func startAppCapture(processID: pid_t, frameRate: Int = 30, maxDimension: Int = 2560) async throws {
        logger.info("Starting app capture for PID: \(processID)")
        
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            logger.error("Failed to get shareable content: \(error.localizedDescription)")
            throw error
        }
        
        guard content.applications.first(where: { $0.processID == processID }) != nil else {
            logger.error("App with PID \(processID) not found")
            throw WindowCaptureError.appNotFound
        }
        
        // Find the app's largest on-screen window (by area) to use as the capture target.
        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == processID && $0.isOnScreen && $0.frame.width > 0 && $0.frame.height > 0
        }
        
        guard let mainWindow = appWindows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            logger.error("No visible windows found for PID \(processID)")
            throw WindowCaptureError.windowNotFound
        }
        
        logger.info("📱 App capture: using window '\(mainWindow.title ?? "Untitled")' (ID: \(mainWindow.windowID)) frame: \(NSStringFromRect(mainWindow.frame))")
        
        // Log CGWindowListCopyWindowInfo bounds for coordinate system verification.
        // SCWindow.frame should match kCGWindowBounds (both Quartz: top-left origin, Y-down).
        if let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, mainWindow.windowID) as? [[String: Any]],
           let info = infoList.first,
           let boundsDict = info[kCGWindowBounds as String] as? NSDictionary {
            var cgRect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(boundsDict, &cgRect) {
                logger.info("📱 CGWindowList bounds (Quartz): \(NSStringFromRect(cgRect))")
                logger.info("📱 SCWindow.frame:               \(NSStringFromRect(mainWindow.frame))")
                if cgRect != mainWindow.frame {
                    logger.warning("⚠️ SCWindow.frame and CGWindowList bounds DIFFER — coordinate system mismatch!")
                }
            }
        }
        
        // Use desktopIndependentWindow — automatically crops to window content,
        // no sourceRect needed, proven approach matching startWindowCapture.
        let filter = SCContentFilter(desktopIndependentWindow: mainWindow)
        
        let retinaScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = mainWindow.frame.width * retinaScale
        let pixelHeight = mainWindow.frame.height * retinaScale
        let scale = min(1.0, Double(maxDimension) / Double(max(pixelWidth, pixelHeight)))
        // Round to even numbers (required for video encoding)
        let width = Int(pixelWidth * scale) & ~1
        let height = Int(pixelHeight * scale) & ~1
        
        // Prefer Quartz (top-left) bounds for input mapping; see startWindowCapture.
        let bounds = Self.quartzWindowBounds(mainWindow.windowID) ?? mainWindow.frame
        captureBounds = bounds
        captureMode = .singleApp(processID)
        
        logger.info("📱 App capture bounds (Quartz): \(NSStringFromRect(bounds)) -> \(width)x\(height) pixels (retina: \(retinaScale)x)")
        try await startStream(with: filter, width: width, height: height, frameRate: frameRate, description: "app '\(mainWindow.title ?? "PID \(processID)")'")
    }
    
    /// The window's on-screen bounds in Quartz coordinates (top-left origin,
    /// Y-down) from CGWindowList. This is the exact space `CGEvent` injection
    /// uses, so mapping remote clicks through it avoids the Y-origin mismatch
    /// that `SCWindow.frame` can introduce for single-window/app streaming.
    private static func quartzWindowBounds(_ windowID: CGWindowID) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(.optionIncludingWindow, windowID) as? [[String: Any]],
              let info = infoList.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary else {
            return nil
        }
        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) else { return nil }
        return rect
    }

    // MARK: - Shared Stream Setup
    
    private func startStream(with filter: SCContentFilter, width: Int, height: Int, frameRate: Int, description: String) async throws {
        if stream != nil {
            await stopCapture()
        }
        
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 3  // Lower buffering for latency; still enough to absorb jitter
        // Region-aware tiling copies tightly-packed 32BGRA sub-rects, so that
        // path stays BGRA. The default video path captures NV12 (full range) to
        // avoid the BGRA->NV12 encode and NV12->BGRA decode conversions; the
        // client samples it with full-range BT.709 coefficients to match.
        config.pixelFormat = regionAwareCapture ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = captureCursor
        activeConfig = config
        
        logger.info("Creating SCStream for \(description)...")
        stream = SCStream(filter: filter, configuration: config, delegate: self)
        
        do {
            try stream?.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            logger.info("Added stream output")
        } catch {
            logger.error("Failed to add stream output: \(error.localizedDescription)")
            throw error
        }
        
        do {
            try await stream?.startCapture()
            logger.info("Capture started for \(description) at \(width)x\(height)@\(frameRate)fps")
        } catch {
            logger.error("Failed to start capture: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Update the capture frame rate live without stopping/restarting the stream.
    /// Uses `SCStream.updateConfiguration()` on macOS 14+; no-op on older versions.
    func updateFrameRate(_ fps: Int) async {
        guard let stream = stream else {
            logger.warning("updateFrameRate: no active stream")
            return
        }
        guard let config = activeConfig else {
            logger.warning("updateFrameRate: no active configuration")
            return
        }

        // Mutate only the frame interval on the existing configuration.
        // updateConfiguration replaces the whole config, so a bare config here
        // would reset width/height/pixelFormat and break the stream (frozen
        // viewer). Reusing activeConfig preserves everything else.
        let newInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        if CMTimeCompare(config.minimumFrameInterval, newInterval) == 0 { return }
        config.minimumFrameInterval = newInterval

        if #available(macOS 14.0, *) {
            do {
                try await stream.updateConfiguration(config)
                logger.info("Live capture update: fps → \(fps)")
            } catch {
                logger.warning("Failed to update capture frame rate: \(error.localizedDescription)")
            }
        } else {
            logger.info("Live capture fps update requires macOS 14+ (current frame rate unchanged)")
        }
    }
    
    /// Update cursor compositing live without stopping/restarting the stream.
    /// Uses `SCStream.updateConfiguration()` on macOS 14+; on older versions
    /// the new value takes effect on the next session.
    func updateCursorCapture(_ show: Bool) async {
        captureCursor = show
        guard let stream = stream, let config = activeConfig else { return }
        if config.showsCursor == show { return }
        config.showsCursor = show

        if #available(macOS 14.0, *) {
            do {
                try await stream.updateConfiguration(config)
                logger.info("Live capture update: showsCursor → \(show)")
            } catch {
                logger.warning("Failed to update cursor capture: \(error.localizedDescription)")
            }
        } else {
            logger.info("Live cursor capture update requires macOS 14+ (applies on next session)")
        }
    }

    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            stream = nil
            activeConfig = nil
            captureMode = nil
            captureBounds = nil
            logger.info("Stopped screen capture")
        } catch {
            logger.error("Failed to stop screen capture: \(error.localizedDescription)")
        }
    }
    
    // MARK: - SCStreamOutput
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        lastFrameChange = parseFrameChange(sampleBuffer)
        delegate?.screenCaptureManager(self, didOutput: sampleBuffer)
    }

    /// Parse ScreenCaptureKit frame info into changed rects + coverage, and log
    /// rolling stats so we can confirm the region-aware payoff and tune the
    /// TILE/VIDEO threshold against real usage.
    private func parseFrameChange(_ sampleBuffer: CMSampleBuffer) -> FrameChangeInfo? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else {
            return nil
        }

        // Non-complete frames (idle/blank/suspended) carry no new content.
        if let statusRaw = info[.status] as? Int,
           let status = SCFrameStatus(rawValue: statusRaw),
           status != .complete {
            recordStat(coverage: 0, idle: true)
            return FrameChangeInfo(dirtyRects: [], coverage: 0, isIdle: true)
        }

        var pixelWidth = 0
        var pixelHeight = 0
        if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) {
            pixelWidth = CVPixelBufferGetWidth(pb)
            pixelHeight = CVPixelBufferGetHeight(pb)
        }

        guard let rectDicts = info[.dirtyRects] as? [[String: Any]] else {
            // Unknown changed area: treat as full-frame change.
            recordStat(coverage: 1, idle: false)
            return FrameChangeInfo(dirtyRects: [], coverage: 1, isIdle: false)
        }

        let rects = rectDicts.compactMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) }
        let totalArea = Double(pixelWidth * pixelHeight)
        let changedArea = rects.reduce(0.0) { $0 + Double($1.width) * Double($1.height) }
        let coverage = totalArea > 0 ? min(1.0, changedArea / totalArea) : 1.0
        recordStat(coverage: coverage, idle: false)
        return FrameChangeInfo(dirtyRects: rects, coverage: coverage, isIdle: false)
    }

    private func recordStat(coverage: Double, idle: Bool) {
        statFrames += 1
        statCoverageSum += coverage
        if idle { statIdle += 1 }
        if !idle && coverage > 0 && coverage < 0.25 { statSmall += 1 }
        if statFrames >= 120 {
            let avg = statCoverageSum / Double(statFrames)
            logger.debug("📐 Dirty-rect stats over \(self.statFrames) frames: avg coverage \(String(format: "%.1f", avg * 100))%, idle \(self.statIdle), small(<25%) \(self.statSmall)")
            statFrames = 0
            statCoverageSum = 0
            statIdle = 0
            statSmall = 0
        }
    }
    
    // MARK: - SCStreamDelegate
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.screenCaptureManager(self, didFailWithError: error)
    }
}
