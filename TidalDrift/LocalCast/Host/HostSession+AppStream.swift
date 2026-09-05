import Foundation
import Network
import CoreGraphics

// App-list enumeration and client-initiated retargeting (stream request).
// Used by the viewer's app picker to switch the LocalCast stream from the
// full desktop to a single app or window (and back). `enumerateShareableApps`
// lives in HostSession+AppEnumeration.swift.
extension HostSession {
    /// Gather available apps and send to client
    func handleAppListRequest(replyTo endpoint: NWEndpoint) async {
        lcDebug("📋 HostSession: Gathering available apps...")

        do {
            let apps = try await Self.enumerateShareableApps()
            allowedAppPIDs = Set(apps.map(\.processID))
            allowedWindowIDs = Set(apps.flatMap { $0.windows.map { CGWindowID($0.windowID) } })

            lcDebug("📋 HostSession: Found \(apps.count) streamable apps")

            // Encode and send
            let encoder = JSONEncoder()
            let payload = try encoder.encode(apps)

            let packet = LocalCastPacket(
                type: .appListResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: payload
            )

            transport.send(packet: packet, to: endpoint)
            lcDebug("📋 HostSession: Sent app list to client (\(payload.count) bytes)")

        } catch {
            logger.warning("Failed to get app list: \(error.localizedDescription) — sending empty list so client can stop loading")
            lcDebug("❌ HostSession: Failed to get app list: \(error)")
            allowedAppPIDs.removeAll()
            allowedWindowIDs.removeAll()
            // Always send a response so the client can clear isLoadingApps (e.g. Screen Recording denied on host)
            let emptyPayload = (try? JSONEncoder().encode([RemoteAppInfo]())) ?? Data()
            let packet = LocalCastPacket(
                type: .appListResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: emptyPayload
            )
            transport.send(packet: packet, to: endpoint)
        }
    }

    func streamRequestValidationError(_ request: StreamRequest) -> String? {
        switch request.type {
        case .fullDisplay:
            return nil
        case .window:
            guard let windowID = request.windowID,
                  allowedWindowIDs.contains(CGWindowID(windowID)) else {
                return "Window was not in the last app list"
            }
        case .app:
            guard let processID = request.processID,
                  allowedAppPIDs.contains(processID) else {
                return "App was not in the last app list"
            }
        }
        return nil
    }

    func sendStreamError(_ message: String, to endpoint: NWEndpoint) {
        let response = StreamResponse(success: false, message: message, streamingTarget: nil)
        if let responsePayload = try? JSONEncoder().encode(response) {
            let packet = LocalCastPacket(
                type: .streamAppResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: responsePayload
            )
            transport.send(packet: packet, to: endpoint)
        }
    }

    /// Handle a request to stream a specific app/window
    func handleStreamRequest(payload: Data, replyTo endpoint: NWEndpoint) async {
        lcDebug("🎬 HostSession: Processing stream request...")
        lcDebug("🎬 HostSession: Payload size: \(payload.count) bytes")

        do {
            // Cap payload size to prevent memory exhaustion from malicious packets
            guard payload.count < 64_000 else {
                throw LocalCastError.connectionFailed("Stream request payload too large (\(payload.count) bytes)")
            }
            let decoder = JSONDecoder()
            let request = try decoder.decode(StreamRequest.self, from: payload)
            if let validationError = streamRequestValidationError(request) {
                lcDebug("❌ HostSession: Stream request rejected: \(validationError)")
                sendStreamError(validationError, to: endpoint)
                return
            }

            lcDebug("🎬 HostSession: Stream request decoded:")
            lcDebug("   Type: \(request.type)")
            lcDebug("   ProcessID: \(request.processID ?? -1)")
            lcDebug("   WindowID: \(request.windowID ?? 0)")
            lcDebug("   AppName: \(request.appName ?? "nil")")

            // Serialize the stop/start with every other capture transition so
            // a concurrent retarget or failure restart cannot interleave.
            try await captureTransitions.runThrowing { [weak self] () throws -> Void in
                guard let self else { return }
                let hadCapture = self.withCaptureState { () -> Bool in
                    let had = self.captureActive
                    self.captureActive = false
                    return had
                }
                if hadCapture {
                    lcDebug("🎬 HostSession: Stopping existing capture...")
                    await self.captureManager.stopCapture()
                    self.encoder.invalidate()
                    lcDebug("🎬 HostSession: Existing capture stopped")
                }

                // Match the capture pixel format (NV12 vs BGRA) to the current
                // region-aware setting in case it was toggled around a stream
                // switch; init and beginCaptureForClient set this, this path did not.
                self.captureManager.regionAwareCapture = self.configuration.regionAware

                // Start the requested capture
                lcDebug("🎬 HostSession: Starting new capture...")
                switch request.type {
                case .fullDisplay:
                    lcDebug("🎬 HostSession: Starting FULL DISPLAY capture")
                    try await self.startFullDisplayCapture()
                    self.captureTarget = .fullDisplay

                case .window:
                    guard let windowID = request.windowID else {
                        lcDebug("❌ HostSession: No window ID in request!")
                        throw LocalCastError.connectionFailed("No window ID provided")
                    }
                    let title = request.appName ?? "Window"
                    lcDebug("🎬 HostSession: Starting WINDOW capture: '\(title)' (ID: \(windowID))")
                    try await self.startWindowCapture(windowID: CGWindowID(windowID))
                    self.captureTarget = .window(CGWindowID(windowID), title: title)

                case .app:
                    guard let processID = request.processID else {
                        lcDebug("❌ HostSession: No process ID in request!")
                        throw LocalCastError.connectionFailed("No process ID provided")
                    }
                    let name = request.appName ?? "App"
                    lcDebug("🎬 HostSession: Starting APP capture: '\(name)' (PID: \(processID))")
                    try await self.startAppCapture(processID: processID)
                    self.captureTarget = .app(processID, name: name)
                }

                self.updateInputBounds()
                self.startWindowTracking()
                self.withCaptureState { self.captureActive = true }
            }

            // Keep the owning service's restart target in sync so a later
            // settings restart keeps streaming this client-chosen window/app.
            let retargetName: String
            switch captureTarget {
            case .fullDisplay:
                retargetName = "Entire Desktop"
            case .window(_, let title):
                retargetName = title
            case .app(_, let name):
                retargetName = name
            }
            onClientRetarget?(captureTarget, retargetName)

            // Force a keyframe so the client decoder can sync to the new stream.
            // The encoder was already primed with forceKeyFrame() before capture started,
            // but send another just in case frames slipped through.
            encoder.forceKeyFrame()
            lcDebug("🎬 HostSession: ✅ New capture running, keyframe forced")

            // Send success response
            let response = StreamResponse(
                success: true,
                message: "Streaming started",
                streamingTarget: request.appName ?? "Display"
            )
            let responsePayload = try JSONEncoder().encode(response)

            let packet = LocalCastPacket(
                type: .streamAppResponse,
                sequenceNumber: 0,
                timestamp: CFAbsoluteTimeGetCurrent() + kCFAbsoluteTimeIntervalSince1970,
                payload: responsePayload
            )
            transport.send(packet: packet, to: endpoint)

            lcDebug("🎬 HostSession: ✅ Started streaming '\(request.appName ?? "Display")'")
            lcDebug("🎬 HostSession: Response sent to client")

        } catch {
            lcDebug("❌ HostSession: Stream request failed: \(error.localizedDescription)")

            // Try to recover by falling back to full display capture
            lcDebug("🔄 HostSession: Recovering -- falling back to full display capture")
            do {
                try await captureTransitions.runThrowing { [weak self] () throws -> Void in
                    guard let self else { return }
                    try await self.startFullDisplayCapture()
                    self.captureTarget = .fullDisplay
                    self.updateInputBounds()
                    self.startWindowTracking()
                    self.isRunning = true
                    // The start path cleared captureActive; restore it here so
                    // suspendCaptureForIdleClient is not left a permanent no-op.
                    self.withCaptureState { self.captureActive = true }
                }
                encoder.forceKeyFrame()
                lcDebug("🔄 HostSession: ✅ Recovered to full display")
            } catch {
                lcDebug("❌ HostSession: Recovery also failed: \(error.localizedDescription)")
            }

            sendStreamError(error.localizedDescription, to: endpoint)
        }
    }
}
