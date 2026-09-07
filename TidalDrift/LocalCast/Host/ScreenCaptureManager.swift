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
    // A dedicated sequencer keeps whole-configuration mutations ordered across
    // suspension points. It is independent of HostSession's outer sequencer;
    // only public entry points enqueue, so internal start/stop cannot recurse.
    private let captureOperations = CaptureTransitionQueue()
    private let outputStreamLock = NSLock()
    private var outputStreamID: ObjectIdentifier?

    private func setOutputStream(_ stream: SCStream?) {
        outputStreamLock.lock()
        outputStreamID = stream.map(ObjectIdentifier.init)
        outputStreamLock.unlock()
    }

    private func isCurrentOutputStream(_ stream: SCStream) -> Bool {
        outputStreamLock.lock(); defer { outputStreamLock.unlock() }
        return outputStreamID == ObjectIdentifier(stream)
    }
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
    /// `updateCursorCapture` applies changes to a live stream.
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
    
    // Capture geometry is written by the capture transition tasks (start/stop)
    // and by HostSession's window tracker, and read from the input injection
    // path, so all of it goes through `geometryLock`.
    private let geometryLock = NSLock()
    private var _captureBounds: CGRect?
    private var _capturedWindowID: CGWindowID?

    /// The screen bounds of the captured content (for input coordinate mapping)
    /// For full display: the display bounds, or nil to track the main display
    /// For window: the window's frame on screen
    /// For app: the frame of the app window being streamed
    var captureBounds: CGRect? {
        geometryLock.lock(); defer { geometryLock.unlock() }
        return _captureBounds
    }

    /// The window the active stream is bound to, for window and app capture
    /// (app capture streams the app's largest window). `HostSession` polls this
    /// window's live geometry so a moved or resized window does not leave input
    /// mapping pointing at where the window used to be.
    var capturedWindowID: CGWindowID? {
        geometryLock.lock(); defer { geometryLock.unlock() }
        return _capturedWindowID
    }

    private func setGeometry(bounds: CGRect?, windowID: CGWindowID?) {
        geometryLock.lock()
        _captureBounds = bounds
        _capturedWindowID = windowID
        geometryLock.unlock()
    }

    /// Re-point input mapping at a moved window without disturbing the stream.
    /// A size change needs more than this: the stream's pixel dimensions are
    /// fixed at creation, so the capture has to be rebuilt.
    func refreshCaptureBounds(_ rect: CGRect) {
        geometryLock.lock()
        _captureBounds = rect
        geometryLock.unlock()
    }
    
    // MARK: - Full Display Capture
    
    func startCapture(displayID: CGDirectDisplayID, width: Int, height: Int, frameRate: Int) async throws {
        try await captureOperations.runThrowing {
            try await self.performStartCapture(displayID: displayID, width: width, height: height, frameRate: frameRate)
        }
    }

    private func performStartCapture(displayID: CGDirectDisplayID, width: Int, height: Int, frameRate: Int) async throws {
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
        
        // Full display capture. nil bounds means "use the main display" for
        // input mapping; when capturing a non-main display (clamshell fallback,
        // external monitor) pass its global Quartz bounds so remote clicks land
        // on the captured display instead of the main one.
        setGeometry(bounds: displayID == CGMainDisplayID() ? nil : CGDisplayBounds(displayID), windowID: nil)
        captureMode = .fullDisplay(displayID)
        try await startStream(with: filter, width: width, height: height, frameRate: frameRate, description: "display \(displayID)")
    }
    
    // MARK: - Single Window Capture
    
    /// Start capturing a specific window by its window ID
    func startWindowCapture(windowID: CGWindowID, frameRate: Int = 30, maxDimension: Int = 2560) async throws {
        try await captureOperations.runThrowing {
            try await self.performStartWindowCapture(windowID: windowID, frameRate: frameRate, maxDimension: maxDimension)
        }
    }

    private func performStartWindowCapture(windowID: CGWindowID, frameRate: Int, maxDimension: Int) async throws {
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
        let retinaScale = Self.backingScale(for: window.frame)
        let pixelWidth = window.frame.width * retinaScale
        let pixelHeight = window.frame.height * retinaScale
        
        let scale: Double
        if pixelWidth > CGFloat(maxDimension) || pixelHeight > CGFloat(maxDimension) {
            scale = Double(maxDimension) / Double(max(pixelWidth, pixelHeight))
        } else {
            scale = 1.0
        }
        
        // Round to even numbers (required for video encoding)
        let width = max(2, Int(pixelWidth * scale) & ~1)
        let height = max(2, Int(pixelHeight * scale) & ~1)
        
        // Store the window's on-screen bounds for input mapping. Prefer the
        // Quartz (top-left origin) bounds from CGWindowList, which match the
        // coordinate space CGEvent injection uses; SCWindow.frame can differ in
        // Y origin and throw remote clicks off when streaming a single window.
        let bounds = Self.quartzWindowBounds(windowID) ?? window.frame
        setGeometry(bounds: bounds, windowID: windowID)
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
        try await captureOperations.runThrowing {
            try await self.performStartAppCapture(processID: processID, frameRate: frameRate, maxDimension: maxDimension)
        }
    }

    private func performStartAppCapture(processID: pid_t, frameRate: Int, maxDimension: Int) async throws {
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
        
        let retinaScale = Self.backingScale(for: mainWindow.frame)
        let pixelWidth = mainWindow.frame.width * retinaScale
        let pixelHeight = mainWindow.frame.height * retinaScale
        let scale = min(1.0, Double(maxDimension) / Double(max(pixelWidth, pixelHeight)))
        // Round to even numbers (required for video encoding)
        let width = max(2, Int(pixelWidth * scale) & ~1)
        let height = max(2, Int(pixelHeight * scale) & ~1)
        
        // Prefer Quartz (top-left) bounds for input mapping; see startWindowCapture.
        let bounds = Self.quartzWindowBounds(mainWindow.windowID) ?? mainWindow.frame
        setGeometry(bounds: bounds, windowID: mainWindow.windowID)
        captureMode = .singleApp(processID)
        
        logger.info("📱 App capture bounds (Quartz): \(NSStringFromRect(bounds)) -> \(width)x\(height) pixels (retina: \(retinaScale)x)")
        try await startStream(with: filter, width: width, height: height, frameRate: frameRate, description: "app '\(mainWindow.title ?? "PID \(processID)")'")
    }
    
    /// The window's on-screen bounds in Quartz coordinates (top-left origin,
    /// Y-down) from CGWindowList. This is the exact space `CGEvent` injection
    /// uses, so mapping remote clicks through it avoids the Y-origin mismatch
    /// that `SCWindow.frame` can introduce for single-window/app streaming.
    static func quartzWindowBounds(_ windowID: CGWindowID) -> CGRect? {
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
    
    /// Choose the display containing the largest part of a Quartz window rect.
    /// Using the main display's scale blurs windows on a different density panel.
    private static func backingScale(for windowRect: CGRect) -> CGFloat {
        let screen = NSScreen.screens.max { lhs, rhs in
            func area(_ screen: NSScreen) -> CGFloat {
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return 0 }
                let overlap = CGDisplayBounds(id).intersection(windowRect)
                return overlap.isNull ? 0 : overlap.width * overlap.height
            }
            return area(lhs) < area(rhs)
        }
        return screen?.backingScaleFactor ?? 1
    }

    private func startStream(with filter: SCContentFilter, width: Int, height: Int, frameRate: Int, description: String) async throws {
        guard width >= 2, height >= 2, frameRate > 0, frameRate <= 240 else {
            throw LocalCastError.connectionFailed("Invalid screen capture dimensions or frame rate.")
        }
        if let previous = stream {
            // Geometry was assigned by the caller for the incoming stream. Do
            // not clear that new geometry while stopping the previous capture.
            stream = nil
            setOutputStream(nil)
            activeConfig = nil
            try? await previous.stopCapture()
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
        if !regionAwareCapture { config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2 }
        config.showsCursor = captureCursor
        // LocalCast is video-only (LocalCastConfiguration.captureAudio is a
        // future flag). Pin both audio knobs explicitly so an SCStream never
        // registers a Core Audio tap on this host: coreaudiod taps created by
        // screen capture are a known CPU-spike source, and relying on the OS
        // default leaves us exposed if a macOS release changes it.
        config.capturesAudio = false
        config.excludesCurrentProcessAudio = true
        let nextStream = SCStream(filter: filter, configuration: config, delegate: self)
        stream = nextStream
        setOutputStream(nextStream)
        activeConfig = config
        do {
            try nextStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
            try await nextStream.startCapture()
            logger.info("Capture started for \(description) at \(width)x\(height)@\(frameRate)fps")
        } catch {
            if stream === nextStream {
                stream = nil
                setOutputStream(nil)
                activeConfig = nil
                captureMode = nil
                setGeometry(bounds: nil, windowID: nil)
            }
            try? nextStream.removeStreamOutput(self, type: .screen)
            logger.error("Failed to start capture: \(error.localizedDescription)")
            throw error
        }
    }

    /// Snapshot all configured capture properties before a live update. Failed
    /// updates leave the applied configuration available for a later retry.
    private func copyConfiguration(_ source: SCStreamConfiguration) -> SCStreamConfiguration {
        let copy = SCStreamConfiguration()
        copy.width = source.width
        copy.height = source.height
        copy.minimumFrameInterval = source.minimumFrameInterval
        copy.queueDepth = source.queueDepth
        copy.pixelFormat = source.pixelFormat
        copy.colorSpaceName = source.colorSpaceName
        if source.pixelFormat != kCVPixelFormatType_32BGRA { copy.colorMatrix = source.colorMatrix }
        copy.showsCursor = source.showsCursor
        copy.capturesAudio = source.capturesAudio
        copy.excludesCurrentProcessAudio = source.excludesCurrentProcessAudio
        return copy
    }

    /// Change cadence in place on every supported macOS release (12.3+ API).
    func updateFrameRate(_ fps: Int) async {
        await captureOperations.run { await self.performUpdateFrameRate(fps) }
    }

    private func performUpdateFrameRate(_ fps: Int) async {
        guard (1...240).contains(fps), let stream, let previous = activeConfig else { return }
        let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        guard CMTimeCompare(previous.minimumFrameInterval, interval) != 0 else { return }
        let next = copyConfiguration(previous)
        next.minimumFrameInterval = interval
        do {
            try await stream.updateConfiguration(next)
            if self.stream === stream { activeConfig = next }
            logger.info("Live capture update: fps → \(fps)")
        } catch {
            logger.warning("Failed to update capture frame rate: \(error.localizedDescription)")
        }
    }

    /// Change cursor compositing without replacing the capture stream.
    func updateCursorCapture(_ show: Bool) async {
        await captureOperations.run { await self.performUpdateCursorCapture(show) }
    }

    private func performUpdateCursorCapture(_ show: Bool) async {
        captureCursor = show
        guard let stream, let previous = activeConfig, previous.showsCursor != show else { return }
        let next = copyConfiguration(previous)
        next.showsCursor = show
        do {
            try await stream.updateConfiguration(next)
            if self.stream === stream { activeConfig = next }
            logger.info("Live capture update: showsCursor → \(show)")
        } catch {
            logger.warning("Failed to update cursor capture: \(error.localizedDescription)")
        }
    }

    func stopCapture() async {
        await captureOperations.run { await self.performStopCapture() }
    }

    private func performStopCapture() async {
        // Detach the stream state first so it is cleared even when the stop
        // call throws. Leaving `stream` set after a failed stop meant a later
        // startStream retried the failing stop and then overwrote the field
        // anyway, leaking a live SCStream that kept delivering stale frames.
        let current = stream
        stream = nil
        setOutputStream(nil)
        activeConfig = nil
        captureMode = nil
        setGeometry(bounds: nil, windowID: nil)
        guard let current else { return }

        do {
            try await current.stopCapture()
            logger.info("Stopped screen capture")
        } catch {
            logger.error("Failed to stop screen capture: \(error.localizedDescription)")
        }
    }
    
    // MARK: - SCStreamOutput
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, isCurrentOutputStream(stream) else { return }
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
        guard isCurrentOutputStream(stream) else { return }
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.screenCaptureManager(self, didFailWithError: error)
    }
}
