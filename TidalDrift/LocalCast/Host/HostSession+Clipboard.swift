import Foundation
import CoreFoundation
import AppKit
import ApplicationServices

/// Identity of the place where a paste was requested. AX element equality
/// compares remote object identity, so opening a different document window or
/// focusing another field in the same app cannot silently redirect a transfer.
struct ClipboardPasteFocus: Equatable {
    let processID: pid_t
    let window: AXUIElement?
    let element: AXUIElement?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.processID == rhs.processID && sameElement(lhs.window, rhs.window)
            && sameElement(lhs.element, rhs.element)
    }

    private static func sameElement(_ lhs: AXUIElement?, _ rhs: AXUIElement?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return CFEqual(lhs, rhs)
        default: return false
        }
    }

    @MainActor
    static func capture() throws -> Self {
        guard AXIsProcessTrusted() else { throw LocalCastError.permissionDenied(.accessibility) }
        guard let app = NSWorkspace.shared.frontmostApplication else { throw LocalCastError.hostNotReady }
        let processID = app.processIdentifier
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.5)

        func focusedElement(_ attribute: String) throws -> AXUIElement? {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(application, attribute as CFString, &value)
            // Finder's desktop can have no focused window. Preserve that nil
            // identity and reject a later transition into an actual window.
            if error == .noValue { return nil }
            if error == .attributeUnsupported, attribute == kAXFocusedUIElementAttribute { return nil }
            guard error == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                throw LocalCastError.clipboardActionFailed("Paste was cancelled because the host's focused window could not be identified.")
            }
            return unsafeBitCast(value, to: AXUIElement.self)
        }

        let snapshot = try Self(processID: processID,
            window: focusedElement(kAXFocusedWindowAttribute),
            element: focusedElement(kAXFocusedUIElementAttribute))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else {
            throw LocalCastError.clipboardActionFailed("Paste was cancelled because the host's active app changed.")
        }
        return snapshot
    }

    func validate(current: Self) throws {
        guard self == current else {
            throw LocalCastError.clipboardActionFailed("Paste was cancelled because the remote app, window, or focused field changed. Select the destination and paste again.")
        }
    }
}

/// Clipboard sync, host side. The engine watches the host pasteboard and
/// applies the client's updates; the bulk listener serves fetches of the
/// host's offers and accepts pushes the host requested. Everything here runs
/// only while a session with an authenticated, non-loopback client is active.
extension HostSession {
    /// Start (or refresh, after a re-auth changes the key) clipboard sync.
    func startClipboardSyncIfEligible() {
        guard isRunning, authState == .authenticated, hasActiveClient, !isLoopbackConnection else { return }

        // The bulk listener only runs on keyed sessions; a keyless session has
        // no way to tell the viewer from any other LAN host on that port.
        if let key = transport.sessionKey.map(SessionCrypto.deriveClipboardKey) {
            let allowedHost = clientEndpoint.flatMap(ClipboardBulkPeerAddress.hostString(from:))
            clipboardBulkHost.start(key: key, allowedHost: allowedHost)
        } else {
            clipboardBulkHost.stop()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let engine = self.clipboardEngine ?? ClipboardSyncEngine()
            self.clipboardEngine = engine

            engine.prepareFileDrop = { [weak self] point in
                guard let self, self.isRunning, self.hasActiveClient, self.isCaptureActive,
                      self.authState == .authenticated, !self.isLoopbackConnection,
                      self.transport.sessionKey != nil, point.isValid else {
                    throw LocalCastError.hostNotReady
                }
                let capturedWindowID = self.captureManager.capturedWindowID
                switch self.captureTarget {
                case .fullDisplay: break
                case .app, .window:
                    guard capturedWindowID != nil else { throw LocalCastError.hostNotReady }
                }
                let bounds = self.inputInjector.captureBounds ?? CGDisplayBounds(CGMainDisplayID())
                guard !bounds.isEmpty else { throw LocalCastError.noDisplayAvailable }
                // AX hit-testing takes Float coordinates; keep edge drops
                // inside the capture after that conversion, too.
                let screenPoint = CGPoint(
                    x: min(bounds.minX + point.x * bounds.width, CGFloat(Float(bounds.maxX).nextDown)),
                    y: min(bounds.minY + point.y * bounds.height, CGFloat(Float(bounds.maxY).nextDown)))
                let destination = try RemoteFileDrop.resolve(
                    at: screenPoint, expectedWindowID: capturedWindowID)
                return { urls in
                    try await Task.detached(priority: .userInitiated) {
                        try RemoteFileDrop.deliver(urls, to: destination)
                    }.value
                }
            }

            engine.preparePasteTarget = { [weak self] in
                guard let self, self.isRunning, self.hasActiveClient,
                      self.authState == .authenticated, !self.isLoopbackConnection else {
                    throw LocalCastError.hostNotReady
                }
                let target = try ClipboardPasteFocus.capture()
                return { try target.validate(current: ClipboardPasteFocus.capture()) }
            }

            engine.performPaste = { [weak self] modifiers in
                guard let self, self.isRunning, self.hasActiveClient,
                      self.authState == .authenticated, !self.isLoopbackConnection else {
                    throw LocalCastError.hostNotReady
                }
                guard self.inputInjector.hasAccessibilityPermission else {
                    throw LocalCastError.permissionDenied(.accessibility)
                }
                self.inputInjector.inject(.keyDown(keyCode: 9, modifiers: modifiers))
                self.inputInjector.inject(.keyUp(keyCode: 9, modifiers: modifiers))
            }
            engine.sendActionResult = { [weak self] result in
                guard let encoded = try? JSONEncoder().encode(result) else { return }
                self?.sendClipboardPacket(type: .clipboardActionResult, payload: encoded, copies: 3)
            }

            engine.sendUpdate = { [weak self] payload in
                guard let encoded = try? JSONEncoder().encode(payload) else { return }
                self?.sendClipboardPacket(type: .clipboardUpdate, payload: encoded)
            }
            engine.publishOutbound = { [weak self] outbound in
                self?.clipboardBulkHost.publishOffer(
                    token: outbound.token, manifest: outbound.manifest, content: outbound.content
                )
            }
            engine.cancelOutbound = { [weak self] in
                self?.clipboardBulkHost.clearOffer()
            }
            // The host cannot connect out to the client, so "fetch" means:
            // arm the push slot for this token, then ask the client to
            // connect and push.
            engine.fetchEager = { [weak self] offer, kind, completion in
                guard let self else { return }
                self.clipboardBulkHost.expectPush(token: offer.token, kind: kind, offer: offer, cacheDir: nil) { result in
                    completion(result)
                }
                self.sendClipboardPacket(type: .clipboardFetchRequest, payload: offer.token, copies: 3)
            }
            engine.fetchFilesForPaste = { [weak self] offer, completion in
                guard let self else {
                    completion(.failure(ClipboardBulkError.cancelled))
                    return
                }
                let cacheDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("TidalDriftClipboard", isDirectory: true)
                self.clipboardBulkHost.expectPush(token: offer.token, kind: .files, offer: offer, cacheDir: cacheDir) { result in
                    switch result {
                    case .success(.files(let urls)):
                        completion(.success(urls))
                    case .success(.data):
                        completion(.failure(ClipboardBulkError.manifestMismatch))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
                self.sendClipboardPacket(type: .clipboardFetchRequest, payload: offer.token, copies: 3)
            }
            engine.isBulkSyncAllowed = { [weak self] in
                self?.transport.sessionKey != nil
            }
            engine.start()
        }
    }

    func stopClipboardSync() {
        clipboardBulkHost.stop()
        DispatchQueue.main.async { [weak self] in
            self?.clipboardEngine?.stop()
        }
    }

    /// Route a clipboard control packet to the active client, preferring its
    /// connection like the video path does.
    func sendClipboardPacket(type: LocalCastPacket.PacketType, payload: Data, copies: Int = 1) {
        let packet = LocalCastPacket(
            type: type,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: payload
        )
        for _ in 0..<copies {
            if let connection = clientConnection {
                transport.send(packet: packet, on: connection)
            } else if let endpoint = clientEndpoint {
                transport.send(packet: packet, to: endpoint)
            }
        }
    }
}
