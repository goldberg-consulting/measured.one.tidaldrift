# App-Sharing Feature Investigation

**Date:** 2025-02
**Scope:** TidalDrift app-sharing (remote app list + app-window control) per `.cursor/agents/app-sharing-investigator.md`

---

## 2026-05 Status

The original infinite-loading failure has been partially addressed: the client now has an app-list timeout, and the LocalCast host sends an empty app-list response when `SCShareableContent` fails. App Control remains an experimental/dormant surface, so current work should focus on avoiding misleading entry points, advertising the host's actual LocalCast auth state, and validating focus/isolate requests against the last app list.

## 1. Data Flow Summary

### LocalCast path (App Control panel + System Screen Share)

| Step | Location | Behavior |
|------|----------|----------|
| **Trigger** | User opens "System Screen Share" from device card → `LocalCastService.connectSystemScreenShare(to:password:)` | Opens VNC via `ScreenShareConnectionService`, then creates `ClientSession(device)`, calls `session.connect(password)`, shows `AppControlPanelController(session)` |
| **Client connect** | `ClientSession.connect()` | Resolves host, sets `hostEndpoint = NWEndpoint.hostPort(host:resolvedAddress, port: 5904)`, starts heartbeats (or auth). No listener on client. |
| **Request** | `AppControlPanelView.onAppear` → after **1.0s** delay → `session.requestAppList()` | Only if `session.remoteApps.isEmpty`. Requires `hostEndpoint != nil` (set in `connect()`). Sends `LocalCastPacket(type: .appListRequest, payload: Data())` via `transport.send(packet:to: hostEndpoint)`. |
| **Host receive** | `HostSession` (UDP 5904) receives packet → `case .appListRequest` | Calls `handleAppListRequest(replyTo: endpoint)` on a `Task` (async). |
| **Host enumerate** | `HostSession.handleAppListRequest(replyTo:)` | `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)` → requires **Screen Recording** on host. Builds `[RemoteAppInfo]`, JSON-encodes, sends `LocalCastPacket(type: .appListResponse, payload: payload)` to same endpoint. |
| **Host failure** | Same method `catch` | Only `print("❌ HostSession: Failed to get app list")`. **Does not send any response to client.** |
| **Client receive** | `ClientSession.udpTransport(_:didReceivePacket:from:)` → `case .appListResponse` | `handleAppListResponse(payload)`: decode `[RemoteAppInfo]`, cap payload &lt; 512KB, then `DispatchQueue.main.async` → `self.remoteApps = apps`, `self.isLoadingApps = false`. |
| **UI** | `AppControlPanelView` | Binds to `session.remoteApps`, `session.isLoadingApps`. Refresh button calls `session.requestAppList()`. |

**Critical dependency:** The host must be **running LocalCast** (`LocalCastService.startHosting()`), which starts `HostSession` and binds UDP 5904. macOS Screen Sharing (VNC) alone does **not** start the LocalCast host. So if the user only has VNC enabled on the host and never starts "LocalCast" hosting in TidalDrift, nothing listens on 5904 → no heartbeat replies, no app-list response → client shows "Connecting..." / "waiting for video" and app list stays empty or loading.

### StreamingNetworkService path (experimental App Streaming tab)

| Step | Location | Behavior |
|------|----------|----------|
| **Discovery** | `StreamingNetworkService` browses `_tidalstream._tcp` | On resolve, `resolveAndConnect(result:serviceName)` opens TCP connection, on `.ready` sends literal `"LIST_APPS"` and calls `receive(minimumIncompleteLength:1, maximumLength:65536)` |
| **Response** | `processAppListResponse(data, from: hostName)` | Expects JSON `[[String:Any]]` with keys `name`, `bundleId`, `windows` (Int). Builds `RemoteStreamableApp` and updates `discoveredHosts`, `allRemoteApps`. |
| **UI** | `AppStreamingView` | Uses `networkService.discoveredHosts` / `networkService.allRemoteApps` (different types than LocalCast `RemoteAppInfo`). |

**Note:** This path uses a **different protocol** (TCP, `LIST_APPS` string, different JSON shape) and a different service (`_tidalstream._tcp`). It is separate from the LocalCast UDP app list.

---

## 2. Root Causes (Client Does Not See Remote Apps)

1. **Host not running LocalCast**
   UDP 5904 is only bound when `LocalCastService.startHosting()` is active on the host. If the user only enabled macOS Screen Sharing (VNC) and did not start LocalCast hosting, no process listens on 5904. The client sends heartbeats and `appListRequest` into the void → no response → app list stays empty and/or loading.

2. **Host lacks Screen Recording permission**
   `HostSession.handleAppListRequest` uses `SCShareableContent.excludingDesktopWindows(...)`, which requires Screen Recording. If the host app does not have it, the current host path sends an empty app list so the client can stop loading, but the user still needs clear permission guidance.

3. **Timeout and error state are required**
   If the host never responds (not hosting, or network failure), the client timeout clears `isLoadingApps` and shows a failure hint. Keep this behavior whenever App Control is refactored.

4. **Firewall / network**
   If the host firewall (or network) drops UDP 5904, the client gets no heartbeat and no app list. Diagnostic timer will eventually set `connectionPhase = .firewallBlocked` (after 6s with no heartbeat), but the app list request is still never answered.

5. **Timing (minor)**
   App Control panel requests the list after a fixed 1s delay. By then `hostEndpoint` is set and heartbeats are in flight, so the request is usually sent. If the host is slow to start or auth is still in progress, the host can still process `appListRequest` when it arrives; no strict ordering is required.

6. **StreamingNetworkService path**
   Remote apps there come from `_tidalstream._tcp` hosts that implement the TCP `LIST_APPS` / custom JSON protocol. If that service is not running or uses a different format, `discoveredHosts` / `allRemoteApps` stay empty for that path only.

---

## 3. Security and Reliability Notes

- **PID validation:** The host does **not** check that a PID in `focusAppRequest` or `isolateAppRequest` was in the app list it previously sent. Any client that can reach the host’s UDP 5904 can send arbitrary PIDs; the host calls `inputInjector.focusApp(pid:)` / `isolateApp(pid:)`. `NSRunningApplication(processIdentifier:)` and `activate` / `hide` only apply to valid PIDs, but a malicious client could still try to focus/hide arbitrary apps (e.g. system UI).
- **Auth:** App list and app-control packets use the same LocalCast channel. If the client connected with password, auth completes before the user sees the panel; app list is then sent over the same (optionally encrypted) channel. No separate auth for “app list only.”
- **Resource use:** One app list request triggers one `SCShareableContent` call on the host. Repeated refresh could be rate-limited; currently the client can spam refresh.
- **Failure handling:** If the host throws in `handleAppListRequest`, the client never gets a response and never clears loading. Malformed or oversized payload on the client is capped (512KB) and decoding errors clear `isLoadingApps` and leave `remoteApps` unchanged.

---

## 4. Recommendation

**Fix (localized changes)**

1. **Host: always respond to app list request**
   In `HostSession.handleAppListRequest(replyTo:)`, in the `catch` block, send an **empty** `appListResponse` (e.g. `payload: "[]".data(using: .utf8)!`) so the client can set `isLoadingApps = false` and show “No apps found” instead of spinning forever. Optionally add a small error flag in the payload later if needed.

2. **Client: loading timeout**
   In `ClientSession.requestAppList()`, after sending the request, schedule a fallback (e.g. 5–8s) that sets `isLoadingApps = false` if it is still true (and optionally show a “Could not load apps” message in the panel). Prevents infinite loading when the host is down or not hosting.

3. **UX: clarify dependency on LocalCast hosting**
   In the App Control panel or when opening System Screen Share, show a short line such as “App list requires the host Mac to have LocalCast turned on.” So users know that VNC alone is not enough for the app list.

4. **Optional: validate PIDs on host**
   Maintain a set of PIDs that were in the last sent app list (or that pass a simple “was recently enumerated” check). In `handleFocusAppRequest` / `handleIsolateAppRequest`, ignore or reject requests whose PID is not in that set (or not in the current shareable content). Reduces abuse from arbitrary PID injection.

**Testing**

- System Screen Share with host **not** running LocalCast: panel should show connection status and, after timeout, stop loading and show empty or error.
- System Screen Share with host running LocalCast but **no** Screen Recording: host should send empty app list; client should show “No apps found” and not spin.
- System Screen Share with host running LocalCast **with** Screen Recording: app list should populate; Focus/Isolate/Stream should work.

---

## 5. Key File References

| File | Relevance |
|------|-----------|
| `TidalDrift/LocalCast/Views/AppControlPanel.swift` | Panel UI; `onAppear` +1s → `requestAppList()`; uses `session.remoteApps`, `session.isLoadingApps`. |
| `TidalDrift/LocalCast/Client/ClientSession.swift` | `requestAppList()` (requires `hostEndpoint`); `udpTransport` → `.appListResponse` → `handleAppListResponse`; `remoteApps`, `isLoadingApps` on main thread. |
| `TidalDrift/LocalCast/Host/HostSession.swift` | `.appListRequest` → `handleAppListRequest(replyTo:)`; `SCShareableContent`; on failure only prints, does not send response. |
| `TidalDrift/LocalCast/Core/LocalCastService.swift` | `connectSystemScreenShare(to:password:)` creates session, calls `connect()`, shows panel. |
| `TidalDrift/LocalCast/Transport/PacketProtocol.swift` | `appListRequest` = 7, `appListResponse` = 8. |
| `TidalDrift/Services/StreamingNetworkService.swift` | `_tidalstream._tcp` path; LIST_APPS over TCP; `processAppListResponse` (different JSON schema). |
| `TidalDrift/Views/Experimental/AppStreamingView.swift` | Uses `StreamingNetworkService` for remote apps (experimental tab). |
