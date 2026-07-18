import Foundation
import CoreGraphics
import OSLog

/// Creates a software display via CoreGraphics' private CGVirtualDisplay
/// classes so a lid-closed or headless host has something for
/// ScreenCaptureKit to capture.
///
/// With the lid closed and no external monitor, the built-in panel drops out
/// of `SCShareableContent.displays` entirely and full-display capture fails
/// with "no display available"; Apple's own Screen Sharing solves this with
/// virtual displays created through a private SkyLight entitlement. The
/// CGVirtualDisplay route is the established third-party equivalent
/// (DeskPad, BetterDisplay, Jump Desktop, Splashtop all ship it) and needs
/// no entitlement for a Developer-ID app.
///
/// Everything is resolved at runtime through the ObjC runtime: these classes
/// have no SDK header, and a signature change in a future macOS must degrade
/// to "no virtual display" (capture fails as before), never a crash. The
/// display lives exactly as long as `display` is strongly retained.
final class VirtualDisplayController {
    private let logger = Logger(subsystem: "com.tidaldrift", category: "VirtualDisplay")

    /// Serializes create/destroy across the capture-transition contexts that
    /// call them (session stop, idle suspend, capture start).
    private let lock = NSLock()

    /// Strong reference keeping the WindowServer display alive.
    private var display: AnyObject?

    /// The Quartz display ID of the live virtual display, or nil.
    private(set) var displayID: CGDirectDisplayID?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return display != nil
    }

    /// 16:9 at a Retina-friendly logical size; capped well under the
    /// streaming pipeline's 4K ceiling.
    private static let pixelsWide = 2560
    private static let pixelsHigh = 1440
    private static let refreshRate = 60.0

    /// Whether this macOS exposes the private classes at the expected shape.
    static var isSupported: Bool {
        NSClassFromString("CGVirtualDisplay") != nil
            && NSClassFromString("CGVirtualDisplayDescriptor") != nil
            && NSClassFromString("CGVirtualDisplaySettings") != nil
            && NSClassFromString("CGVirtualDisplayMode") != nil
    }

    /// Create the virtual display and wait for WindowServer to register it.
    /// Returns the new display ID, or nil when unsupported or rejected
    /// (macOS 14 betas transiently refused creation with zero physical
    /// displays attached, so callers should retry once).
    func create() -> CGDirectDisplayID? {
        lock.lock(); defer { lock.unlock() }
        if let displayID, display != nil { return displayID }

        guard Self.isSupported else {
            logger.warning("CGVirtualDisplay classes unavailable on this macOS — cannot create a virtual display")
            return nil
        }

        guard
            let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor") as? NSObject.Type,
            let settingsClass = NSClassFromString("CGVirtualDisplaySettings") as? NSObject.Type,
            let modeClass = NSClassFromString("CGVirtualDisplayMode") as? NSObject.Type,
            let displayClass = NSClassFromString("CGVirtualDisplay")
        else { return nil }

        // Descriptor: plain init + KVC property sets (all declared @objc
        // properties on the private class, so KVC resolves the setters).
        let descriptor = descriptorClass.init()
        descriptor.setValue("TidalDrift Virtual Display", forKey: "name")
        descriptor.setValue(Self.pixelsWide, forKey: "maxPixelsWide")
        descriptor.setValue(Self.pixelsHigh, forKey: "maxPixelsHigh")
        descriptor.setValue(CGSize(width: 600, height: 340), forKey: "sizeInMillimeters")
        // Arbitrary but stable identity so macOS reuses display settings.
        descriptor.setValue(0x54_44, forKey: "vendorID")   // "TD"
        descriptor.setValue(0x56_44, forKey: "productID")  // "VD"
        descriptor.setValue(1, forKey: "serialNum")
        descriptor.setValue(DispatchQueue.main, forKey: "queue")

        // CGVirtualDisplay: alloc + initWithDescriptor:. The init consumes
        // alloc's +1 and returns +1, so claim exactly one retain.
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithDescriptor:")
        guard
            let allocated = (displayClass as AnyObject).perform(allocSel)?.takeUnretainedValue(),
            allocated.responds(to: initSel),
            let instance = allocated.perform(initSel, with: descriptor)?.takeRetainedValue()
        else {
            logger.error("CGVirtualDisplay allocation failed")
            return nil
        }

        // Mode: initWithWidth:height:refreshRate: takes three arguments, so
        // it goes through the raw IMP instead of perform(_:with:with:).
        let modeInitSel = NSSelectorFromString("initWithWidth:height:refreshRate:")
        guard
            let modeAlloc = (modeClass as AnyObject).perform(allocSel)?.takeUnretainedValue(),
            let modeMethod = class_getInstanceMethod(modeClass, modeInitSel)
        else {
            logger.error("CGVirtualDisplayMode init unavailable")
            return nil
        }
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt, UInt, Double) -> Unmanaged<AnyObject>?
        let modeInit = unsafeBitCast(method_getImplementation(modeMethod), to: ModeInit.self)
        guard let mode = modeInit(modeAlloc, modeInitSel, UInt(Self.pixelsWide), UInt(Self.pixelsHigh), Self.refreshRate)?.takeRetainedValue() else {
            logger.error("CGVirtualDisplayMode creation failed")
            return nil
        }

        let settings = settingsClass.init()
        settings.setValue([mode], forKey: "modes")
        settings.setValue(1, forKey: "hiDPI")

        // applySettings: returns BOOL; go through the IMP for the result.
        let applySel = NSSelectorFromString("applySettings:")
        guard let applyMethod = class_getInstanceMethod(object_getClass(instance), applySel) else {
            logger.error("CGVirtualDisplay applySettings: unavailable")
            return nil
        }
        typealias ApplySettings = @convention(c) (AnyObject, Selector, AnyObject) -> Bool
        let apply = unsafeBitCast(method_getImplementation(applyMethod), to: ApplySettings.self)
        guard apply(instance, applySel, settings) else {
            logger.error("CGVirtualDisplay applySettings: rejected")
            return nil
        }

        guard let idNumber = instance.value(forKey: "displayID") as? NSNumber else {
            logger.error("CGVirtualDisplay has no displayID")
            return nil
        }

        let id = CGDirectDisplayID(idNumber.uint32Value)
        display = instance
        displayID = id
        logger.info("🖥️ Virtual display created: ID \(id) (\(Self.pixelsWide)x\(Self.pixelsHigh)@\(Int(Self.refreshRate)))")
        return id
    }

    /// Release the display; WindowServer tears it down when the last
    /// reference drops.
    func destroy() {
        lock.lock(); defer { lock.unlock() }
        guard display != nil else { return }
        display = nil
        displayID = nil
        logger.info("🖥️ Virtual display released")
    }

    deinit {
        display = nil
    }
}
