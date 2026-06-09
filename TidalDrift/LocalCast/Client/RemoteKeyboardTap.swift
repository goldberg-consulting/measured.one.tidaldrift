import AppKit
import CoreGraphics
import OSLog

/// Captures keyboard events at the session level so system shortcuts
/// (Cmd+Space for Spotlight, Cmd+Tab, Mission Control, screenshot combos, etc.)
/// can be forwarded to the remote host instead of being consumed locally.
///
/// A plain `NSEvent` local monitor never sees system hotkeys: the window server
/// dispatches them before the responder chain. A `CGEventTap` sits ahead of that
/// dispatch, so it can both observe and swallow them. The tap only acts while
/// `shouldCapture` returns true (viewer is key + remote input enabled); the rest
/// of the time every event passes through untouched.
///
/// Requires Accessibility permission (the same grant the host uses to inject
/// input). If the tap can't be created, the caller should fall back to an
/// `NSEvent` monitor, which still handles ordinary keys.
final class RemoteKeyboardTap {
    /// Forward a key event to the host. `down` is true for key-down.
    var onKey: ((_ keyCode: UInt16, _ modifiers: UInt64, _ down: Bool) -> Void)?

    /// The user's release hotkey fired (Cmd+Shift+I), so capture can be toggled
    /// off and the user is never trapped while system shortcuts are swallowed.
    var onToggleCapture: (() -> Void)?

    /// Whether events should be captured and forwarded right now.
    var shouldCapture: (() -> Bool)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.tidaldrift", category: "RemoteKeyboardTap")

    /// Only the device-independent modifier bits. These line up with
    /// `NSEvent.ModifierFlags` and the host's `CGEventFlags(rawValue:)`, so the
    /// remote sees the same modifier state we do.
    private static let modifierMask: UInt64 = UInt64(
        CGEventFlags.maskAlphaShift.rawValue |
        CGEventFlags.maskShift.rawValue |
        CGEventFlags.maskControl.rawValue |
        CGEventFlags.maskAlternate.rawValue |
        CGEventFlags.maskCommand.rawValue |
        CGEventFlags.maskSecondaryFn.rawValue
    )

    /// Install the tap. Returns false if creation failed (e.g. permission), so
    /// the caller can fall back to an NSEvent monitor.
    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<RemoteKeyboardTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            logger.error("Could not create keyboard event tap (Accessibility permission?)")
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        logger.info("Remote keyboard tap installed (system shortcuts will forward)")
        return true
    }

    func stop() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }

    deinit { stop() }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables a tap that takes too long or after some user input;
        // re-enable and pass the event through.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard shouldCapture?() == true else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Release hotkey: Cmd+Shift+I toggles capture so the user can always get
        // local control back even while we're swallowing Cmd+Tab/Cmd+Q/etc.
        if type == .keyDown,
           flags.contains(.maskCommand), flags.contains(.maskShift),
           keyCode == 34 {
            onToggleCapture?()
            return nil
        }

        let modifiers = UInt64(flags.rawValue) & Self.modifierMask

        switch type {
        case .keyDown:
            onKey?(keyCode, modifiers, true)
        case .keyUp:
            onKey?(keyCode, modifiers, false)
        case .flagsChanged:
            // Modifier press/release. Forward as key-down carrying the new flag
            // set so the host mirrors the modifier state; subsequent key events
            // carry the same flags, so combos like Cmd+Space resolve correctly.
            onKey?(keyCode, modifiers, true)
        default:
            return Unmanaged.passUnretained(event)
        }
        return nil
    }
}
