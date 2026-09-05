import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import OSLog

/// Virtual key codes of the modifier keys, paired with the `CGEventFlags` bit
/// each one contributes.
///
/// A `flagsChanged` event says which modifier changed but not whether it went
/// down or up, so the client recovers the direction by testing the key's own
/// bit against the new flag set, and the host uses the same table to know which
/// modifiers are still latched.
enum ModifierKey {
    static let flagsByKeyCode: [UInt16: CGEventFlags] = [
        54: .maskCommand,     // right command
        55: .maskCommand,     // left command
        56: .maskShift,       // left shift
        60: .maskShift,       // right shift
        58: .maskAlternate,   // left option
        61: .maskAlternate,   // right option
        59: .maskControl,     // left control
        62: .maskControl,     // right control
        57: .maskAlphaShift,  // caps lock
        63: .maskSecondaryFn  // fn
    ]

    static func isModifier(_ keyCode: UInt16) -> Bool {
        flagsByKeyCode[keyCode] != nil
    }

    /// Whether a `flagsChanged` event for `keyCode` is a press rather than a
    /// release, judged by whether the key's own bit is still set in the flags
    /// the event carries. Returns nil when `keyCode` is not a modifier.
    static func isPress(keyCode: UInt16, flags: CGEventFlags) -> Bool? {
        guard let bit = flagsByKeyCode[keyCode] else { return nil }
        return flags.contains(bit)
    }
}

class InputInjector {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "InputInjector")
    private var inputCount = 0
    private var lastPermissionCheck: Date?
    private var hasLoggedPermissionWarning = false

    /// Modifier keys the client pressed but has not released. Injected modifier
    /// key-downs latch at the HID level, so a release that never arrives leaves
    /// every later keystroke reading as a shortcut, which presents as a dead
    /// keyboard on the host. Tracked so the latch can be cleared on departure.
    /// `inject(_:)` runs on the transport queue but `releaseHeldInput()` is
    /// called from the capture callback and the idle timer, so the held state
    /// is guarded.
    private var heldModifierKeyCodes: Set<UInt16> = []
    private let heldStateLock = NSLock()
    
    /// The capture bounds for input mapping (defaults to full screen)
    /// When capturing a window/app, this should be set to the window's frame.
    /// Written by the capture transition tasks and by the window tracker as the
    /// streamed window moves, read on the input path, hence the lock.
    private var _captureBounds: CGRect?
    private let captureBoundsLock = NSLock()
    var captureBounds: CGRect? {
        get { captureBoundsLock.lock(); defer { captureBoundsLock.unlock() }; return _captureBounds }
        set { captureBoundsLock.lock(); _captureBounds = newValue; captureBoundsLock.unlock() }
    }

    /// Mouse button currently held down (0 = left, 1 = right, 2 = other), so a
    /// subsequent move can be injected as a drag rather than a plain move.
    /// Guarded by `heldStateLock`.
    private var heldMouseButton: Int?

    /// Limits the release-visible click-mapping diagnostic to the first few clicks.
    private var mouseDownLogCount = 0
    
    enum RemoteInput {
        case mouseMove(x: Double, y: Double)
        case mouseDown(button: Int, x: Double, y: Double)
        case mouseUp(button: Int, x: Double, y: Double)
        case keyDown(keyCode: UInt16, modifiers: UInt64)
        case keyUp(keyCode: UInt16, modifiers: UInt64)
        /// `precise` mirrors NSEvent.hasPreciseScrollingDeltas: true for
        /// trackpads/Magic Mouse (deltas are pixels), false for a physical
        /// scroll wheel (deltas are lines). The host must inject with the
        /// matching CGScrollEventUnit or wheel scrolling is ~20x too slow.
        case scroll(deltaX: Double, deltaY: Double, precise: Bool)
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
    /// The modifier bits a remote keystroke may carry. Everything else in the
    /// 64-bit flag word (device-dependent and reserved bits) is stripped.
    static let allowedModifierMask: UInt64 = CGEventFlags([
        .maskShift, .maskControl, .maskAlternate, .maskCommand,
        .maskAlphaShift, .maskSecondaryFn, .maskNumericPad, .maskHelp,
    ]).rawValue

    /// Command chords that still make sense when a single window or app is
    /// shared: select all, save, find, undo/redo, cut, copy, paste, and
    /// Command+arrow navigation. Anything else with Command held (Cmd+Q,
    /// Cmd+Tab, Cmd+Space, Ctrl+Cmd+Q, Cmd+Shift+Q, Cmd+Option+Esc, the
    /// screenshot chords) acts on the host as a whole, not the shared window.
    static let scopedCommandAllowlist: Set<UInt16> = [
        0, 1, 3, 6, 7, 8, 9,      // A S F Z X C V
        123, 124, 125, 126,       // left right down up
    ]

    /// Flags to inject for a remote keystroke, or nil when the keystroke must
    /// be dropped. In scoped (window/app) mode Command chords are limited to
    /// `scopedCommandAllowlist`; bare modifier presses always pass so the
    /// allowed chords can be formed. Full-display mode only masks the flags.
    static func keystrokeFlags(keyCode: UInt16, modifiers: UInt64, scoped: Bool) -> CGEventFlags? {
        let flags = CGEventFlags(rawValue: modifiers & allowedModifierMask)
        guard scoped, !ModifierKey.isModifier(keyCode), flags.contains(.maskCommand) else { return flags }
        return scopedCommandAllowlist.contains(keyCode) ? flags : nil
    }

    /// Clamp a wire coordinate into the unit interval. NaN and infinities
    /// (raw bit patterns off the network) map to 0.
    static func clampNormalized(_ value: Double) -> Double {
        value.isFinite ? min(max(value, 0), 1) : 0
    }

    private func normalizedToScreenCoordinates(x rawX: Double, y rawY: Double) -> CGPoint {
        // Clamp so a single-window viewer can only ever click inside the
        // shared window, never on the rest of the host desktop.
        let x = Self.clampNormalized(rawX)
        let y = Self.clampNormalized(rawY)
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
                lcDebug("🚨 InputInjector: Accessibility permission DENIED - input will not work!")
                lcDebug("🚨 InputInjector: Go to System Settings > Privacy & Security > Accessibility and enable TidalDrift")
                logger.error("🚨 InputInjector: Accessibility permission DENIED - input will not work!")
                hasLoggedPermissionWarning = true
            } else if hasPermission && inputCount == 1 {
                lcDebug("✅ InputInjector: Accessibility permission granted")
                logger.info("✅ InputInjector: Accessibility permission granted")
            }
        }
        
        // Log first few inputs and then periodically to verify receipt and coordinate mapping
        if inputCount <= 10 || inputCount % 200 == 0 {
            lcDebug("🎮 InputInjector: Injecting input #\(self.inputCount): \(String(describing: input))")
            if let bounds = captureBounds {
                lcDebug("🎮 InputInjector: captureBounds: origin=(\(Int(bounds.origin.x)),\(Int(bounds.origin.y))) size=(\(Int(bounds.width))x\(Int(bounds.height)))")
            } else {
                let db = CGDisplayBounds(CGMainDisplayID())
                lcDebug("🎮 InputInjector: Full display mode, displayBounds=(\(Int(db.origin.x)),\(Int(db.origin.y)),\(Int(db.width))x\(Int(db.height)))")
            }
        }
        
        switch input {
        case .mouseMove(let x, let y):
            let point = normalizedToScreenCoordinates(x: x, y: y)
            // While a button is held, a move is a *drag*. AppKit's window/title-bar
            // and selection tracking loops consume `.leftMouseDragged` (not
            // `.mouseMoved`), so sending plain moves made drags jump to the drop
            // point instead of tracking. Emit the matching dragged event for the
            // held button so drags follow the cursor live.
            let moveType: CGEventType
            let moveButton: CGMouseButton
            heldStateLock.lock()
            let held = heldMouseButton
            heldStateLock.unlock()
            if let held {
                moveType = held == 0 ? .leftMouseDragged : (held == 1 ? .rightMouseDragged : .otherMouseDragged)
                moveButton = CGMouseButton(rawValue: UInt32(held)) ?? .left
            } else {
                moveType = .mouseMoved
                moveButton = .left
            }
            guard let event = CGEvent(mouseEventSource: nil, mouseType: moveType, mouseCursorPosition: point, mouseButton: moveButton) else {
                if inputCount <= 5 { logger.error("❌ Failed to create mouseMove event") }
                return
            }
            event.post(tap: .cghidEventTap)
            
        case .mouseDown(let button, let x, let y):
            let point = normalizedToScreenCoordinates(x: x, y: y)
            // Release-visible mapping log for the first few clicks so a coordinate
            // offset (esp. single-window/app streaming) can be diagnosed from a
            // normal build via Console: filter subsystem com.tidaldrift.
            if mouseDownLogCount < 4 {
                mouseDownLogCount += 1
                let b = captureBounds.map { "(\(Int($0.origin.x)),\(Int($0.origin.y)) \(Int($0.width))x\(Int($0.height)))" } ?? "fullDisplay"
                logger.info("🖱️ map norm(\(String(format: "%.3f", x)), \(String(format: "%.3f", y))) -> screen(\(Int(point.x)), \(Int(point.y))) bounds=\(b)")
            }
            let type: CGEventType = button == 0 ? .leftMouseDown : (button == 1 ? .rightMouseDown : .otherMouseDown)
            guard let mouseButton = CGMouseButton(rawValue: UInt32(button)),
                  let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else {
                lcDebug("[INPUT-DIAG] ❌ INJECT FAILED: could not create mouseDown CGEvent at norm(\(x), \(y))")
                return
            }
            heldStateLock.lock()
            heldMouseButton = button
            heldStateLock.unlock()
            lcDebug("[INPUT-DIAG] 💉 INJECTING mouseDown button=\(button) at screen(\(Int(point.x)), \(Int(point.y))) from norm(\(String(format: "%.3f", x)), \(String(format: "%.3f", y))) bounds=\(String(describing: captureBounds))")
            event.post(tap: .cghidEventTap)
            
        case .mouseUp(let button, let x, let y):
            let point = normalizedToScreenCoordinates(x: x, y: y)
            let type: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            guard let mouseButton = CGMouseButton(rawValue: UInt32(button)),
                  let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: mouseButton) else {
                lcDebug("[INPUT-DIAG] ❌ INJECT FAILED: could not create mouseUp CGEvent at norm(\(x), \(y))")
                return
            }
            heldStateLock.lock()
            if heldMouseButton == button { heldMouseButton = nil }
            heldStateLock.unlock()
            lcDebug("[INPUT-DIAG] 💉 INJECTING mouseUp button=\(button) at screen(\(Int(point.x)), \(Int(point.y)))")
            event.post(tap: .cghidEventTap)
            
        case .keyDown(let keyCode, let modifiers):
            guard let flags = Self.keystrokeFlags(keyCode: keyCode, modifiers: modifiers, scoped: captureBounds != nil) else {
                lcDebug("[INPUT-DIAG] 🚫 keyDown keyCode=\(keyCode) blocked in single-window mode")
                return
            }
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true) else {
                lcDebug("[INPUT-DIAG] ❌ INJECT FAILED: could not create keyDown CGEvent for keyCode \(keyCode)")
                return
            }
            event.flags = flags
            if ModifierKey.isModifier(keyCode) {
                heldStateLock.lock()
                heldModifierKeyCodes.insert(keyCode)
                heldStateLock.unlock()
            }
            lcDebug("[INPUT-DIAG] 💉 INJECTING keyDown keyCode=\(keyCode) modifiers=\(modifiers)")
            event.post(tap: .cghidEventTap)
            
        case .keyUp(let keyCode, let modifiers):
            guard let flags = Self.keystrokeFlags(keyCode: keyCode, modifiers: modifiers, scoped: captureBounds != nil) else {
                return
            }
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
                lcDebug("[INPUT-DIAG] ❌ INJECT FAILED: could not create keyUp CGEvent for keyCode \(keyCode)")
                return
            }
            event.flags = flags
            heldStateLock.lock()
            heldModifierKeyCodes.remove(keyCode)
            heldStateLock.unlock()
            lcDebug("[INPUT-DIAG] 💉 INJECTING keyUp keyCode=\(keyCode)")
            event.post(tap: .cghidEventTap)
            
        case .scroll(let deltaX, let deltaY, let precise):
            // Precise (trackpad/Magic Mouse) deltas are pixels; wheel deltas
            // are lines. Injecting lines as pixels made one wheel notch move
            // ~1 pixel instead of ~1 line, which read as "scrolling barely
            // works" with a physical mouse.
            let units: CGScrollEventUnit = precise ? .pixel : .line
            // Round away from zero so a single notch or a slow trackpad drift
            // is never truncated to a no-op.
            let dy = Int32(deltaY.rounded(.toNearestOrAwayFromZero))
            let dx = Int32(deltaX.rounded(.toNearestOrAwayFromZero))
            guard dx != 0 || dy != 0 else { return }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else {
                logger.error("❌ Failed to create scroll event")
                return
            }
            if inputCount <= 5 || inputCount % 100 == 0 {
                logger.info("🔄 InputInjector: scroll deltaX=\(deltaX), deltaY=\(deltaY), units=\(precise ? "pixel" : "line")")
            }
            event.post(tap: .cghidEventTap)
        }
    }

    /// Release every modifier key still latched from injected input, and any
    /// held mouse button. Call this when the client goes away: UDP gives no
    /// disconnect guarantee, so a release can be lost in flight, and a latched
    /// Command key makes the host keyboard appear broken to whoever is sitting
    /// in front of it.
    func releaseHeldInput() {
        heldStateLock.lock()
        let stuckKeys = heldModifierKeyCodes
        heldModifierKeyCodes.removeAll()
        let stuckButton = heldMouseButton
        heldMouseButton = nil
        heldStateLock.unlock()

        for keyCode in stuckKeys {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else { continue }
            event.flags = []
            event.post(tap: .cghidEventTap)
        }

        if let button = stuckButton {
            let type: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            let location = CGEvent(source: nil)?.location ?? .zero
            if let mouseButton = CGMouseButton(rawValue: UInt32(button)),
               let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton) {
                event.post(tap: .cghidEventTap)
            }
        }

        if !stuckKeys.isEmpty {
            logger.info("⌨️ Released \(stuckKeys.count) latched modifier key(s) after client departure")
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
        case .scroll(let deltaX, let deltaY, let precise):
            data.append(6)
            var dx = deltaX.bitPattern.bigEndian
            var dy = deltaY.bitPattern.bigEndian
            withUnsafeBytes(of: &dx) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &dy) { data.append(contentsOf: $0) }
            data.append(precise ? 1 : 0)
        }
        return data
    }
    
    /// Highest mouse button index the wire format accepts. `CGMouseButton` has
    /// exactly three cases; anything else off the network is rejected here so
    /// the injector never has to handle it.
    static let maxMouseButton = 2

    static func deserialize(_ raw: Data) -> InputInjector.RemoteInput? {
        // Re-base so absolute offsets below are correct even for a slice.
        let data = raw.startIndex == 0 ? raw : Data(raw)
        guard !data.isEmpty else { return nil }

        func u64(_ range: Range<Int>) -> UInt64 {
            data.subdata(in: range).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).bigEndian }
        }
        func u16(_ range: Range<Int>) -> UInt16 {
            data.subdata(in: range).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).bigEndian }
        }

        switch data[0] {
        case 1: // mouseMove
            guard data.count >= 17 else { return nil }
            return .mouseMove(x: Double(bitPattern: u64(1..<9)), y: Double(bitPattern: u64(9..<17)))
        case 2, 3: // mouseDown / mouseUp
            guard data.count >= 18, data[1] <= maxMouseButton else { return nil }
            let button = Int(data[1])
            let x = Double(bitPattern: u64(2..<10))
            let y = Double(bitPattern: u64(10..<18))
            return data[0] == 2 ? .mouseDown(button: button, x: x, y: y) : .mouseUp(button: button, x: x, y: y)
        case 4, 5: // keyDown / keyUp
            guard data.count >= 11 else { return nil }
            let keyCode = u16(1..<3)
            let modifiers = u64(3..<11)
            return data[0] == 4 ? .keyDown(keyCode: keyCode, modifiers: modifiers) : .keyUp(keyCode: keyCode, modifiers: modifiers)
        case 6: // scroll
            guard data.count >= 17 else { return nil }
            let dx = Double(bitPattern: u64(1..<9))
            let dy = Double(bitPattern: u64(9..<17))
            // 17-byte payloads come from builds that predate the precise flag;
            // they always injected as pixels, so keep that reading for them.
            let precise = data.count >= 18 ? data[17] == 1 : true
            return .scroll(deltaX: dx, deltaY: dy, precise: precise)
        default:
            return nil
        }
    }
}
