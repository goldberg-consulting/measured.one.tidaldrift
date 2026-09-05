import Foundation
import CoreFoundation

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
                self.clipboardBulkHost.expectPush(token: offer.token, kind: kind, cacheDir: nil) { result in
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
                self.clipboardBulkHost.expectPush(token: offer.token, kind: .files, cacheDir: cacheDir) { result in
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
