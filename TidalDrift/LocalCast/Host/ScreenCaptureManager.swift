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
    
    deinit {
        if let stream = stream {
            stream.stopCapture { _ in }
        }
        stream = nil
    }
    
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
        
        // Store the window's screen bounds for input mapping
        captureBounds = window.frame
        captureMode = .singleWindow(windowID)
        
        logger.info("🪟 Window capture bounds: \(NSStringFromRect(window.frame))")
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
        
        captureBounds = mainWindow.frame
        captureMode = .singleApp(processID)
        
        logger.info("📱 App capture bounds: \(NSStringFromRect(mainWindow.frame)) -> \(width)x\(height) pixels (retina: \(retinaScale)x)")
        try await startStream(with: filter, width: width, height: height, frameRate: frameRate, description: "app '\(mainWindow.title ?? "PID \(processID)")'")
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
        config.queueDepth = 5  // Enough frames queued for consistent 60 FPS delivery
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        
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
        
        if #available(macOS 14.0, *) {
            let config = SCStreamConfiguration()
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            
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
    
    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            stream = nil
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
        delegate?.screenCaptureManager(self, didOutput: sampleBuffer)
    }
    
    // MARK: - SCStreamDelegate
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("Stream stopped with error: \(error.localizedDescription)")
        delegate?.screenCaptureManager(self, didFailWithError: error)
    }
}
