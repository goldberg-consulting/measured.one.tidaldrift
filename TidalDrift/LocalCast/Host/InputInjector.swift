import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import OSLog

class InputInjector {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "InputInjector")
    private var inputCount = 0
    private var lastPermissionCheck: Date?
    private var hasLoggedPermissionWarning = false
    
    /// The capture bounds for input mapping (defaults to full screen)
    /// When capturing a window/app, this should be set to the window's frame
    var captureBounds: CGRect?
    
    enum RemoteInput {
        case mouseMove(x: Double, y: Double)
        case mouseDown(button: Int, x: Double, y: Double)
        case mouseUp(button: Int, x: Double, y: Double)
        case keyDown(keyCode: UInt16, modifiers: UInt64)
        case keyUp(keyCode: UInt16, modifiers: UInt64)
        case scroll(deltaX: Double, deltaY: Double)
    }
    
    /// Check if we have Accessibility permission (required for input injection)
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }
    
    /// Request accessibility permission (opens System Settings)
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
    
    // MARK: - Remote App Focus
    
    /// Bring the application with the given PID to the foreground.
    /// Uses NSRunningApplication.activate which does not require Accessibility permission.
    func focusApp(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            logger.warning("Cannot focus app — PID \(pid) not found")
            return
        }
        let ok = app.activate(options: [.activateIgnoringOtherApps])
        if ok {
            logger.info("✅ Focused app '\(app.localizedName ?? "PID \(pid)")' (PID \(pid))")
        } else {
            logger.warning("Failed to activate app PID \(pid)")
        }
    }
    
    // MARK: - App Isolation (for VNC single-app view)
    
    /// PIDs of apps we hid during isolation, so we can restore them later.
    private var isolatedHiddenPIDs: [pid_t] = []
    
    /// The PID of the currently isolated app, if any.
    private(set) var isolatedAppPID: pid_t?
    
    /// Hide every regular (non-target, non-TidalDrift) app and activate the target.
    /// Designed for use with System Screen Sharing (VNC) so only one app is visible.
    func isolateApp(pid: pid_t) {
        guard let targetApp = NSRunningApplication(processIdentifier: pid) else {
            logger.warning("Cannot isolate — PID \(pid) not found")
            return
        }
        
        restoreApps()
        
        var hidden: [pid_t] = []
        let ownBundleID = Bundle.main.bundleIdentifier ?? ""
        
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.processIdentifier != pid,
                  app.bundleIdentifier != ownBundleID,
                  !app.isHidden else { continue }
            
            if app.hide() {
                hidden.append(app.processIdentifier)
            }
        }
        
        isolatedHiddenPIDs = hidden
        isolatedAppPID = pid
        targetApp.activate(options: [.activateIgnoringOtherApps])
        
        logger.info("🔒 Isolated '\(targetApp.localizedName ?? "PID \(pid)")' — hid \(hidden.count) other apps")
    }
    
    /// Unhide all apps that were hidden by `isolateApp(pid:)`.
    func restoreApps() {
        guard !isolatedHiddenPIDs.isEmpty else { return }
        
        var restored = 0
        for pid in isolatedHiddenPIDs {
            if let app = NSRunningApplication(processIdentifier: pid) {
                if app.unhide() { restored += 1 }
            }
        }
        
        logger.info("🔓 Restored \(restored)/\(self.isolatedHiddenPIDs.count) apps")
        isolatedHiddenPIDs.removeAll()
        isolatedAppPID = nil
    }
    
    // MARK: - Remote Window Resize
    
    /// Resize a window belonging to the given process using the Accessibility API.
    /// For apps with multiple windows the focused (frontmost) window is resized.
    func resizeWindow(pid: pid_t, to size: CGSize) {
        guard hasAccessibilityPermission else {
            logger.warning("📐 Cannot resize window — Accessibility permission not granted")
            return
        }
        
        let appElement = AXUIElementCreateApplication(pid)
        
        // Try the focused window first (most intuitive target)
        var targetWindow: AXUIElement?
        var focusedRef: AnyObject?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success {
            targetWindow = (focusedRef as! AXUIElement)
        }
        
        // Fallback: first window in the list
        if targetWindow == nil {
            var windowsRef: AnyObject?
            if AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
               let windows = windowsRef as? [AXUIElement],
               let first = windows.first {
                targetWindow = first
            }
        }
        
        guard let window = targetWindow else {
            logger.error("📐 No windows found for PID \(pid)")
            return
        }
        
        var newSize = size
        guard let sizeValue = AXValueCreate(.cgSize, &newSize) else {
            logger.error("📐 Failed to create AXValue for size \(Int(size.width))x\(Int(size.height))")
            return
        }
        
        let result = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if result == .success {
            logger.info("📐 ✅ Resized window (PID \(pid)) to \(Int(size.width))x\(Int(size.height))")
        } else {
            logger.error("📐 ❌ Failed to resize window (PID \(pid)): AXError \(result.rawValue)")
        }
    }
    
    /// Convert normalized coordinates (0...1) to Quartz screen coordinates.
    ///
    /// CGEvent uses Quartz display coordinates where (0,0) is the TOP-LEFT of
    /// the primary display and Y increases downward.
    ///
    /// ScreenCaptureKit's `SCWindow.frame` (and `captureBounds`) uses the same
    /// Quartz coordinate system — origin at top-left, Y increases downward
    /// (matching CGWindowListCopyWindowInfo / kCGWindowBounds).
    ///
    /// The client sends normalized coordinates where x=0,y=0 is the top-left of
    /// the captured content and (1,1) is the bottom-right.
    private func normalizedToScreenCoordinates(x: Double, y: Double) -> CGPoint {
        if let bounds = captureBounds {
            // Window/app capture — captureBounds is already in Quartz coordinates
            // (origin = top-left of the captured area on screen).
            let screenX = bounds.origin.x + (CGFloat(x) * bounds.width)
            let screenY = bounds.origin.y + (CGFloat(y) * bounds.height)
            return CGPoint(x: screenX, y: screenY)
        } else {
            // Full display mode — normalized coords map to the full display
            // in Quartz space (y=0 is top, y=1 is bottom).
            // Use CGDisplayBounds which is documented to return the display rect
            // in the global display coordinate space (points, not pixels).
            let displayBounds = CGDisplayBounds(CGMainDisplayID())
            return CGPoint(
                x: displayBounds.origin.x + x * displayBounds.width,
                y: displayBounds.origin.y + y * displayBounds.height
            )
        }
    }
    
    func inject(_ input: RemoteInput) {
        inputCount += 1
        
        // Check and log permission status periodically
        if inputCount == 1 || inputCount % 100 == 0 {
            let hasPermission = hasAccessibilityPermission
            if !hasPermission && !hasLoggedPermissionWarning {
                print("🚨 InputInjector: Accessibility permission DENIED - input will not work!")
                print("🚨 InputInjector: Go to System Settings > Privacy & Security > Accessibility and enable TidalDrift")
                logger.error("🚨 InputInjector: Accessibility permission DENIED - input will not work!")
                hasLoggedPermissionWarning = true
            } else if hasPermission && inputCount == 1 {
                print("✅ InputInjector: Accessibility permission granted")
                logger.info("✅ InputInjector: Accessibility permission granted")
            }
        }
        
        // Log first few inputs and then periodically to verify receipt and coordinate mapping
        if inputCount <= 10 || inputCount % 200 == 0 {
            print("🎮 InputInjector: Injecting input #\(self.inputCount): \(String(describing: input))")
            if let bounds = captureBounds {
                print("🎮 InputInjector: captureBounds: origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) size=(\(Int(bounds.width))x\(Int(bounds.height)))")
            } else {
                let db = CGDisplayBounds(CGMainDisplayID())
                print("🎮 InputInjector: Full display mode, displayBounds=(\(Int(db.origin.x)),\(Int(db.origin.y)),\(Int(db.width))x\(Int(db.height)))")
            }
        }
        
        switch input {
        case .mouseMove(let x, let y):
            let point = normalizedToScreenCoordinates(x: x, y: y)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
                if inputCount <= 5 { logger.error("❌ Failed to create mouseMove event") }
                return
            }
            event.post(tap: .cghidEventTap)
            
        case .mouseDown(let button, let x, let y):
            let point = normalizedToScreenCoordinates(x: x, y: y)
            let type: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(button))!) else {
                print("[INPUT-DIAG] ❌ INJECT FAILED: could not create mouseDown CGEvent at norm(\(x), \(y))")
                return
            }
            print("[INPUT-DIAG] 💉 INJECTING mouseDown button=\(button) at screen(\(Int(point.x)), \(Int(point.y))) from norm(\(String(format: "%.3f", x)), \(String(format: "%.3f", y))) bounds=\(String(describing: captureBounds))")
            event.post(tap: .cghidEventTap)
            
        case .mouseUp(let button, let x, let y):
            let point = normalizedToScreenCoordinates(x: x, y: y)
            let type: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: CGMouseButton(rawValue: UInt32(button))!) else {
                print("[INPUT-DIAG] ❌ INJECT FAILED: could not create mouseUp CGEvent at norm(\(x), \(y))")
                return
            }
            print("[INPUT-DIAG] 💉 INJECTING mouseUp button=\(button) at screen(\(Int(point.x)), \(Int(point.y)))")
            event.post(tap: .cghidEventTap)
            
        case .keyDown(let keyCode, let modifiers):
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
                print("[INPUT-DIAG] ❌ INJECT FAILED: could not create keyDown CGEvent for keyCode \(keyCode)")
                return
            }
            event.flags = CGEventFlags(rawValue: modifiers)
            print("[INPUT-DIAG] 💉 INJECTING keyDown keyCode=\(keyCode) modifiers=\(modifiers)")
            event.post(tap: .cghidEventTap)
            
        case .keyUp(let keyCode, let modifiers):
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                print("[INPUT-DIAG] ❌ INJECT FAILED: could not create keyUp CGEvent for keyCode \(keyCode)")
                return
            }
            event.flags = CGEventFlags(rawValue: modifiers)
            print("[INPUT-DIAG] 💉 INJECTING keyUp keyCode=\(keyCode)")
            event.post(tap: .cghidEventTap)
            
        case .scroll(let deltaX, let deltaY):
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) else {
                logger.error("❌ Failed to create scroll event")
                return
            }
            if inputCount <= 5 || inputCount % 100 == 0 {
                logger.info("🔄 InputInjector: scroll deltaX=\(deltaX), deltaY=\(deltaY)")
            }
            event.post(tap: .cghidEventTap)
        }
    }
}

extension InputInjector.RemoteInput {
    func serialize() -> Data {
        var data = Data()
        switch self {
        case .mouseMove(let x, let y):
            data.append(1)
            var xb = x.bitPattern.bigEndian
            var yb = y.bitPattern.bigEndian
            withUnsafeBytes(of: &xb) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &yb) { data.append(contentsOf: $0) }
        case .mouseDown(let button, let x, let y):
            data.append(2)
            data.append(UInt8(button))
            var xb = x.bitPattern.bigEndian
            var yb = y.bitPattern.bigEndian
            withUnsafeBytes(of: &xb) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &yb) { data.append(contentsOf: $0) }
        case .mouseUp(let button, let x, let y):
            data.append(3)
            data.append(UInt8(button))
            var xb = x.bitPattern.bigEndian
            var yb = y.bitPattern.bigEndian
            withUnsafeBytes(of: &xb) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &yb) { data.append(contentsOf: $0) }
        case .keyDown(let keyCode, let modifiers):
            data.append(4)
            var k = keyCode.bigEndian
            var m = modifiers.bigEndian
            withUnsafeBytes(of: &k) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        case .keyUp(let keyCode, let modifiers):
            data.append(5)
            var k = keyCode.bigEndian
            var m = modifiers.bigEndian
            withUnsafeBytes(of: &k) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &m) { data.append(contentsOf: $0) }
        case .scroll(let deltaX, let deltaY):
            data.append(6)
            var dx = deltaX.bitPattern.bigEndian
            var dy = deltaY.bitPattern.bigEndian
            withUnsafeBytes(of: &dx) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &dy) { data.append(contentsOf: $0) }
        }
        return data
    }
    
    static func deserialize(_ data: Data) -> InputInjector.RemoteInput? {
        guard !data.isEmpty else { return nil }
        let type = data[0]
        switch type {
        case 1: // mouseMove
            guard data.count >= 17 else { return nil }
            let x = Double(bitPattern: data.subdata(in: 1..<9).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            let y = Double(bitPattern: data.subdata(in: 9..<17).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            return .mouseMove(x: x, y: y)
        case 2: // mouseDown
            guard data.count >= 18 else { return nil }
            let button = Int(data[1])
            let x = Double(bitPattern: data.subdata(in: 2..<10).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            let y = Double(bitPattern: data.subdata(in: 10..<18).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            return .mouseDown(button: button, x: x, y: y)
        case 3: // mouseUp
            guard data.count >= 18 else { return nil }
            let button = Int(data[1])
            let x = Double(bitPattern: data.subdata(in: 2..<10).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            let y = Double(bitPattern: data.subdata(in: 10..<18).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            return .mouseUp(button: button, x: x, y: y)
        case 4: // keyDown
            guard data.count >= 11 else { return nil }
            let keyCode = data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let modifiers = data.subdata(in: 3..<11).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            return .keyDown(keyCode: keyCode, modifiers: modifiers)
        case 5: // keyUp
            guard data.count >= 11 else { return nil }
            let keyCode = data.subdata(in: 1..<3).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
            let modifiers = data.subdata(in: 3..<11).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian }
            return .keyUp(keyCode: keyCode, modifiers: modifiers)
        case 6: // scroll
            guard data.count >= 17 else { return nil }
            let dx = Double(bitPattern: data.subdata(in: 1..<9).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            let dy = Double(bitPattern: data.subdata(in: 9..<17).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
            return .scroll(deltaX: dx, deltaY: dy)
        default:
            return nil
        }
    }
}
