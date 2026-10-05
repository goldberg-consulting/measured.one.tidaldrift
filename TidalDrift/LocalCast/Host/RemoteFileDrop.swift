import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Resolves a Finder drop target once, then copies verified received files into that folder.
/// Other applications require their own drop protocol and are deliberately unsupported.
enum RemoteFileDrop {
    struct Destination: Sendable {
        let directoryURL: URL
        fileprivate let device: dev_t
        fileprivate let inode: ino_t
    }

    /// An immutable accessibility snapshot keeps target selection independent of later focus changes.
    struct TargetSnapshot {
        let isFinder: Bool
        let ancestry: [ElementSnapshot]
    }

    struct ElementSnapshot {
        let role: String?
        let documentURL: URL?
        let itemURL: URL?
    }

    /// Quartz supplies these windows in front-to-back order.
    struct WindowSnapshot {
        let id: CGWindowID
        let ownerPID: pid_t
        let bounds: CGRect
        let alpha: Double
    }

    enum DropError: LocalizedError {
        case accessibilityRequired
        case unsupportedTarget
        case unavailableDestination
        case capturedWindowUnavailable
        case destinationChanged
        case invalidFile
        case deliveryFailed(completed: Int, reason: String)

        var errorDescription: String? {
            switch self {
            case .accessibilityRequired:
                return "Enable Accessibility for TidalDrift on the receiving Mac to drop files."
            case .unsupportedTarget:
                return "Drop files onto an open Finder folder. This target does not support file drops."
            case .unavailableDestination:
                return "The Finder folder at the drop location is unavailable or is not writable."
            case .capturedWindowUnavailable:
                return "Bring the shared Finder window to the front on the receiving Mac, then drop the files again."
            case .destinationChanged:
                return "The destination folder moved or changed while the files were being transferred. Drop them again."
            case .invalidFile:
                return "Only regular files can be dropped. Folders and symbolic links are not supported."
            case .deliveryFailed(let completed, let reason):
                let prefix = completed == 0 ? "No files were saved." : "Saved \(completed) file(s) before the drop stopped."
                return "\(prefix) \(reason)"
            }
        }
    }

    /// Hit-tests top-left screen coordinates, respecting the actual window stacking order.
    @MainActor
    static func resolve(at screenPoint: CGPoint, expectedWindowID: CGWindowID? = nil) throws -> Destination {
        guard AXIsProcessTrusted() else { throw DropError.accessibilityRequired }
        guard screenPoint.x.isFinite, screenPoint.y.isFinite,
              abs(screenPoint.x) <= CGFloat(Float.greatestFiniteMagnitude),
              abs(screenPoint.y) <= CGFloat(Float.greatestFiniteMagnitude) else {
            throw DropError.unsupportedTarget
        }
        // Quartz visibility checks and AX must test the same Float-representable point.
        let hitPoint = CGPoint(x: CGFloat(Float(screenPoint.x)), y: CGFloat(Float(screenPoint.y)))
        let scopedWindow = try expectedWindowID.map {
            try validateVisibleWindow(at: hitPoint, expectedWindowID: $0, windows: visibleWindows())
        }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(hitPoint.x), Float(hitPoint.y), &hit) == .success,
              let hit else { throw DropError.unsupportedTarget }
        var pid: pid_t = 0
        guard AXUIElementGetPid(hit, &pid) == .success,
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.finder" else {
            throw DropError.unsupportedTarget
        }
        // A captured click-through overlay must not resolve a Finder window underneath it.
        if let scopedWindow, scopedWindow.ownerPID != pid { throw DropError.capturedWindowUnavailable }

        var ancestry: [ElementSnapshot] = []
        var current: AXUIElement? = hit
        // Malformed or cyclic accessibility trees must not stall the control channel.
        for _ in 0..<48 {
            guard let element = current else { break }
            var owner: pid_t = 0
            guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { break }
            let role = attribute(kAXRoleAttribute, of: element) as? String
            ancestry.append(ElementSnapshot(
                role: role,
                documentURL: urlAttribute(attribute(kAXDocumentAttribute, of: element)),
                itemURL: urlAttribute(attribute(kAXURLAttribute, of: element))
            ))
            if role == kAXWindowRole as String { break }
            current = parent(of: element)
        }
        if let scopedWindow {
            let currentWindow = try validateVisibleWindow(
                at: hitPoint, expectedWindowID: scopedWindow.id, windows: visibleWindows())
            guard currentWindow.ownerPID == pid, currentWindow.bounds == scopedWindow.bounds else {
                throw DropError.capturedWindowUnavailable
            }
        }
        return try resolve(snapshot: TargetSnapshot(isFinder: true, ancestry: ancestry))
    }

    /// A desktop-independent stream can show an obscured window. Never deliver into its cover.
    /// Treat every visible intersecting Quartz window as a possible cover, including overlays.
    static func validateVisibleWindow(
        at point: CGPoint, expectedWindowID: CGWindowID, windows: [WindowSnapshot]
    ) throws -> WindowSnapshot {
        guard point.x.isFinite, point.y.isFinite, expectedWindowID != kCGNullWindowID else {
            throw DropError.capturedWindowUnavailable
        }
        for window in windows {
            guard window.alpha.isFinite,
                  window.bounds.origin.x.isFinite, window.bounds.origin.y.isFinite,
                  window.bounds.width.isFinite, window.bounds.height.isFinite else {
                throw DropError.capturedWindowUnavailable
            }
            guard window.alpha > 0, window.bounds.contains(point) else { continue }
            guard window.id == expectedWindowID else { throw DropError.capturedWindowUnavailable }
            return window
        }
        throw DropError.capturedWindowUnavailable
    }

    private static func visibleWindows() throws -> [WindowSnapshot] {
        // Apple's optionOnScreenOnly contract guarantees front-to-back ordering.
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            throw DropError.capturedWindowUnavailable
        }
        return try list.map { window in
            guard let id = window[kCGWindowNumber as String] as? NSNumber,
                  let owner = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let alpha = window[kCGWindowAlpha as String] as? NSNumber,
                  let dictionary = window[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else {
                throw DropError.capturedWindowUnavailable
            }
            return WindowSnapshot(id: id.uint32Value, ownerPID: owner.int32Value,
                                  bounds: bounds, alpha: alpha.doubleValue)
        }
    }

    /// Selects the closest directory represented by the hit element or its Finder window.
    /// No selected-item, current-window, frontmost-app, or Desktop fallback is used.
    static func resolve(snapshot: TargetSnapshot) throws -> Destination {
        guard snapshot.isFinder,
              let windowIndex = snapshot.ancestry.firstIndex(where: { $0.role == kAXWindowRole as String }) else {
            throw DropError.unsupportedTarget
        }
        for element in snapshot.ancestry[...windowIndex] {
            for candidate in [element.itemURL, element.documentURL].compactMap({ $0 }) {
                // An explicit URL identifies this target. Falling through from a file,
                // search view, or vanished folder would silently redirect the drop.
                guard candidate.isFileURL else { throw DropError.unsupportedTarget }
                let directory = candidate.standardizedFileURL.resolvingSymlinksInPath()
                guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
                    throw DropError.unavailableDestination
                }
                // A Finder application/package icon is a distinct drop target, not a folder.
                guard values.isPackage != true else { throw DropError.unsupportedTarget }
                guard values.isDirectory == true else { throw DropError.unsupportedTarget }
                let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw DropError.unavailableDestination }
                defer { close(descriptor) }
                var info = stat()
                guard fstat(descriptor, &info) == 0,
                      faccessat(descriptor, ".", W_OK, 0) == 0 else { throw DropError.unavailableDestination }
                return Destination(directoryURL: directory, device: info.st_dev, inode: info.st_ino)
            }
        }
        throw DropError.unsupportedTarget
    }

    /// Copies staged regular files without overwriting existing names. Call off the main actor.
    /// The caller must authenticate, size-limit, and verify received files before delivery.
    /// If a later file fails, the error explicitly reports how many earlier files were saved.
    static func deliver(_ stagedFiles: [URL], to destination: Destination) throws -> [URL] {
        guard !stagedFiles.isEmpty else { throw DropError.invalidFile }
        let descriptor = open(destination.directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DropError.destinationChanged }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_dev == destination.device, info.st_ino == destination.inode else {
            throw DropError.destinationChanged
        }
        var delivered: [URL] = []
        do {
            for source in stagedFiles {
                try Task.checkCancellation()
                let name = try copy(source, into: descriptor)
                delivered.append(destination.directoryURL.appendingPathComponent(name))
                // The descriptor prevents redirection during a copy. Detect a concurrent
                // move too, so success never returns paths into a replacement folder.
                var current = stat()
                guard lstat(destination.directoryURL.path, &current) == 0,
                      current.st_dev == destination.device, current.st_ino == destination.inode else {
                    throw DropError.destinationChanged
                }
            }
        } catch {
            throw DropError.deliveryFailed(completed: delivered.count, reason: error.localizedDescription)
        }
        return delivered
    }

    private static func copy(_ source: URL, into directory: Int32) throws -> String {
        let filename = source.lastPathComponent
        guard source.isFileURL, !filename.isEmpty, filename != ".", filename != "..",
              !filename.contains(":"), !filename.contains("\0"), filename.utf8.count <= 255 else {
            throw DropError.invalidFile
        }
        // O_NONBLOCK prevents an unexpected FIFO from blocking before fstat can reject it.
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw DropError.invalidFile }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw DropError.invalidFile
        }
        let temporaryName = ".localcast-\(UUID().uuidString)"
        let output = openat(directory, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw posixError() }
        defer {
            close(output)
            unlinkat(directory, temporaryName, 0)
        }
        guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else { throw posixError() }
        try Task.checkCancellation()
        // Publish only a complete copy. RENAME_EXCL closes the check-then-copy overwrite race.
        for suffix in 0..<10_000 {
            let name = uniqueName(filename, suffix: suffix)
            if renameatx_np(directory, temporaryName, directory, name, UInt32(RENAME_EXCL)) == 0 {
                return name
            }
            guard errno == EEXIST else { throw posixError() }
        }
        throw DropError.deliveryFailed(completed: 0, reason: "Too many files with the same name already exist in this folder.")
    }

    private static func uniqueName(_ original: String, suffix: Int) -> String {
        guard suffix > 0 else { return original }
        let path = original as NSString
        let ext = path.pathExtension
        let ending = " (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
        var stem = path.deletingPathExtension
        // Preserve Unicode scalar boundaries while staying within APFS's filename byte limit.
        while (stem + ending).utf8.count > 255, !stem.isEmpty { stem.removeLast() }
        return stem + ending
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    private static func attribute(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func parent(of element: AXUIElement) -> AXUIElement? {
        guard let value = attribute(kAXParentAttribute, of: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // Core Foundation's runtime type check above establishes the concrete AX reference type.
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func urlAttribute(_ value: CFTypeRef?) -> URL? {
        if let url = value as? URL { return url }
        guard let string = value as? String else { return nil }
        return URL(string: string)
    }
}
