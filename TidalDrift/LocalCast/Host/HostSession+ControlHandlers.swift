import Foundation
import AppKit
import Network
import OSLog

// MARK: - Auth handshake and remote-control packet handlers
//
// Split from HostSession.swift for file size; these are the self-contained
// handlers dispatched from `udpTransport(_:didReceivePacket:...)`. Session
// state they touch goes through the lock-backed properties on HostSession.

extension HostSession {

    // MARK: - Auth Handshake (Host Side)

    /// Re-arm the handshake after the previous client goes away. The transport
    /// drops every plaintext packet while a key is installed, so without this
    /// reset a new client's authRequest could never be processed.
    func resetAuthForNewClient() {
        guard hostPassword != nil else { return }
        sessionKey = SessionCrypto.generateSessionKey()
        transport.sessionKey = nil
        clientNonce = nil
        hostNonce = nil
        authState = .waitingForAuth
        logger.info("🔐 Auth re-armed, waiting for new client")
    }

    /// Handle authRequest from client: generate hostNonce, derive pairingKey, encrypt sessionKey, reply with authChallenge.
    func handleAuthRequest(payload: Data, from endpoint: NWEndpoint) {
        guard payload.count == 32 else {
            logger.warning("🔐 authRequest: bad nonce length (\(payload.count))")
            return
        }
        guard let password = hostPassword, let sessionKey = sessionKey else {
            logger.warning("🔐 authRequest received but no password/session key (auth disabled?)")
            return
        }

        // Store client nonce
        clientNonce = payload

        // Generate our nonce
        let hNonce = SessionCrypto.generateNonce()
        hostNonce = hNonce

        // Derive pairing key from password + nonces
        let pairingKey = SessionCrypto.derivePairingKey(password: password, clientNonce: payload, hostNonce: hNonce)

        // Encrypt the real session key with the pairing key
        let sessionKeyData = SessionCrypto.exportKey(sessionKey)
        guard let encryptedSessionKey = SessionCrypto.encrypt(sessionKeyData, using: pairingKey) else {
            logger.error("🔐 Failed to encrypt session key for authChallenge")
            return
        }

        // Build challenge payload: hostNonce (32) + encryptedSessionKey
        var challengePayload = Data()
        challengePayload.append(hNonce)
        challengePayload.append(encryptedSessionKey)

        let challenge = LocalCastPacket(
            type: .authChallenge,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: challengePayload
        )
        transport.send(packet: challenge, to: endpoint)
        logger.info("🔐 Sent authChallenge to client (\(challengePayload.count) bytes)")

        // authChallenge is a single plaintext datagram with no retransmit
        // layer; if it is lost the client re-sends authRequest, but resending
        // the challenge proactively converges faster. Stop once the handshake
        // completes or a newer authRequest replaced the nonces.
        for delay in [0.4, 1.0] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning,
                      self.authState == .waitingForAuth,
                      self.hostNonce == hNonce else { return }
                self.transport.send(packet: challenge, to: endpoint)
                self.logger.info("🔐 Resent authChallenge (+\(delay)s)")
            }
        }
    }

    /// Handle authComplete from client: verify proof, activate encryption, send authSuccess.
    func handleAuthComplete(payload: Data, from endpoint: NWEndpoint) {
        guard let sessionKey = sessionKey else { return }

        // The client sends AES-GCM(sessionKey, "AUTH-OK") as proof it derived the correct key.
        guard let proof = SessionCrypto.decrypt(payload, using: sessionKey) else {
            logger.warning("🔐 authComplete: decryption failed — wrong PIN?")
            return
        }

        guard String(data: proof, encoding: .utf8) == "AUTH-OK" else {
            logger.warning("🔐 authComplete: proof mismatch")
            return
        }

        // Auth succeeded — enable encryption on the transport
        authState = .authenticated
        transport.sessionKey = sessionKey
        logger.info("🔐 ✅ Client authenticated — encryption enabled")

        // Send authSuccess (encrypted with session key now that transport has the key)
        let successPacket = LocalCastPacket(
            type: .authSuccess,
            sequenceNumber: 0,
            timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
            payload: Data("AUTH-SUCCESS".utf8)
        )
        transport.send(packet: successPacket, to: endpoint)

        // authSuccess is a single UDP datagram, and once the key is installed
        // the client's plaintext authComplete retransmits are dropped at the
        // transport, so a lost authSuccess cannot be recovered reactively. It
        // would deadlock the session in the worst way: both sides hold the key
        // and video flows, but the client never starts heartbeats, so the host
        // idle-drops it ~10 seconds after it appeared to work. Resend a couple
        // of times; the client ignores duplicates.
        for delay in [0.4, 1.2] {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.isRunning, self.authState == .authenticated else { return }
                self.transport.send(packet: successPacket, to: endpoint)
            }
        }

        // The just-authenticated client becomes the active viewer (takeover).
        // Route by endpoint (connection: nil) so video can't go to a stale
        // previous client's connection.
        setActiveClient(endpoint: endpoint, connection: nil)
        beginCaptureForClient()
        forceInitialKeyframes()
    }

    // MARK: - Window Resize

    func handleWindowResize(payload: Data) {
        guard payload.count >= 16 else { return }

        let width = Double(bitPattern: payload.subdata(in: 0..<8).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })
        let height = Double(bitPattern: payload.subdata(in: 8..<16).withUnsafeBytes { $0.load(as: UInt64.self).bigEndian })

        switch captureTarget {
        case .fullDisplay:
            // Nothing to resize in full display mode
            return
        case .window, .app:
            break
        }

        guard let pid = targetPID else {
            logger.warning("📐 Resize requested but no target PID stored")
            return
        }

        if isLoopbackConnection {
            // On loopback, resizing would fight with the user's own window.
            lcDebug("📐 HostSession: Loopback — skipping remote resize")
            return
        }

        logger.info("📐 Resizing remote window (PID \(pid)) to \(Int(width))x\(Int(height))")
        inputInjector.resizeWindow(pid: pid, to: CGSize(width: width, height: height))
    }

    // MARK: - Focus App

    /// Bring a remote app to the foreground. Payload is a JSON-encoded FocusRequest.
    func handleFocusAppRequest(payload: Data) {
        struct FocusRequest: Decodable {
            let processID: pid_t
            let appName: String?
        }

        guard let request = try? JSONDecoder().decode(FocusRequest.self, from: payload) else {
            logger.warning("focusAppRequest: could not decode payload")
            return
        }
        guard allowedAppPIDs.contains(request.processID) else {
            logger.warning("focusAppRequest: rejected PID \(request.processID), not in last app list")
            return
        }

        logger.info("🎯 Focus request: '\(request.appName ?? "PID \(request.processID)")' (PID \(request.processID))")
        inputInjector.focusApp(pid: request.processID)
    }

    // MARK: - App Isolation (VNC single-app mode)

    func handleIsolateAppRequest(payload: Data) {
        struct IsolateRequest: Decodable {
            let processID: pid_t
            let appName: String?
        }

        guard let request = try? JSONDecoder().decode(IsolateRequest.self, from: payload) else {
            logger.warning("isolateAppRequest: could not decode payload")
            return
        }
        guard allowedAppPIDs.contains(request.processID) else {
            logger.warning("isolateAppRequest: rejected PID \(request.processID), not in last app list")
            return
        }

        logger.info("🔒 Isolate request: '\(request.appName ?? "PID \(request.processID)")' (PID \(request.processID))")
        inputInjector.isolateApp(pid: request.processID)
    }

    func handleRestoreAppsRequest() {
        logger.info("🔓 Restore apps request")
        inputInjector.restoreApps()
    }

    func handleQualityUpdate(payload: Data) {
        guard let update = try? JSONDecoder().decode(QualityUpdatePayload.self, from: payload) else {
            logger.warning("qualityUpdate: could not decode payload")
            return
        }
        let tuning = StreamingTuning()
        tuning.apply(update)
        logger.info("🎚️ Quality update from client: q=\(update.quality), fps=\(tuning.effectiveFps), bitrate=\(tuning.effectiveBitrateMbps)Mbps")
        updateStreamingQuality(tuning)
    }
}
