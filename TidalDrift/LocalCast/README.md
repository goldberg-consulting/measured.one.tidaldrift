# TidalCast: Screen and App Streaming for macOS

> **Status:** TidalCast's full-desktop VNC streaming (Tier 1) is fully functional. App-window streaming (Tier 2, the custom pipeline described below) is now functional: capture, encode, transport, decode, and render run end to end, and the recent two-stage viewer watchdog resolves the freeze that used to follow a host settings restart. Remaining limitations are honest ones: the client-driven in-viewer app picker is currently dormant (host-initiated sharing via the menu-bar picker is the active path), the password key derivation is not yet a brute-force-resistant hash (see "What is next"), and cross-machine behavior still depends on the link (UDP has no retransmit, so a lossy uplink can still break frames). Contributions are welcome.

TidalCast is TidalDrift's streaming engine with a two-tier architecture:

## Tier 1: Full Desktop (VNC)

Full-desktop sharing uses **macOS built-in Screen Sharing** (`vnc://`). Apple handles encoding, compression, input forwarding, clipboard sync, and authentication natively. No custom code is required; TidalDrift opens the URL directly.

## Tier 2: App/Window Streaming (this code)

For streaming a **single app or window** as a native-looking client window, TidalCast employs a custom pipeline built on Apple's low-level frameworks. The host captures a display, window, or app via ScreenCaptureKit, encodes it with VideoToolbox (HEVC preferred, H.264 fallback), and sends it over UDP. The client decodes and renders in a Metal-backed NSWindow. The full-frame video path stays in NV12 from capture through render to avoid color-format conversions; see "Pixel format" below.

## Why the custom pipeline exists

VNC shares the entire desktop. When the goal is to treat a remote app as if it were running locally, with its own window, its own title bar, and input scoped to that window, per-window capture and rendering are required. macOS provides the building blocks (ScreenCaptureKit, VideoToolbox, Metal) but does not expose per-window VNC. TidalCast wires them together.

## Architecture

The pipeline runs in-process. No external daemons, no ffmpeg, no GStreamer. Each stage is a focused component:

```
┌─────────────────────────── HOST ───────────────────────────┐
│                                                             │
│  ScreenCaptureKit ──▶ VideoEncoder ──────▶ UDPTransport     │
│  (SCStream;           (VTCompression        (NWListener     │
│   NV12 video /         HEVC/H.264,           + 1400B frag,  │
│   BGRA tiles)          Annex B)              FEC, pacing)   │
│                                                             │
│  InputInjector ◀────────────────────────── UDPTransport    │
│  (CGEvent.post)                              (receive)      │
└─────────────────────────────────────────────────────────────┘
                          ▲  UDP :5904  ▼
┌────────────────────────── CLIENT ──────────────────────────┐
│                                                             │
│  UDPTransport ──────▶ VideoDecoder ──────▶ MetalRenderer    │
│  (NWConnection         (VTDecompression     (MTKView;       │
│   + reassembly,         HEVC/H.264,          NV12 YUV /     │
│   FEC recovery)         NV12 out)            BGRA shaders,  │
│                                              jitter buffer) │
│  Event monitors ─────────────────────────▶ UDPTransport    │
│  (NSEvent)             normalized coords     (send)         │
└─────────────────────────────────────────────────────────────┘
```

### Host side (`LocalCast/Host/`)

- **ScreenCaptureManager**: Wraps ScreenCaptureKit's `SCStream`. Supports three capture modes: full display, single window, single app. The capture pixel format is chosen at stream start from `configuration.regionAware`: the default video path captures NV12 (4:2:0 biplanar, full range, `kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) so the IOSurface stays zero-copy into VideoToolbox and Metal; the region-aware tile path captures 32BGRA so dirty sub-rects can be copied tightly packed. Parses per-frame dirty-rect/coverage info for region-aware mode. Cursor compositing (`showsCursor`) is off by default; `updateFrameRate` and `updateCursorCapture` apply live on macOS 14+ via `SCStream.updateConfiguration`. Delivers `CMSampleBuffer` frames to the host session via delegate.

- **VideoEncoder**: Creates a `VTCompressionSession` (HEVC or H.264; falls back to H.264 if HEVC session creation fails), enabling Apple's low-latency rate controller (`EnableLowLatencyRateControl`, Apple Silicon, macOS 11.3+). Converts output from AVCC to Annex B and prepends parameter sets (SPS/PPS, plus VPS for HEVC) on keyframes. Keyframe interval is 1.5 s at setup; the live quality slider drives an effective interval of 2.0 to 5.0 s. Bitrate spans 15 to 100 Mbps across presets, 8 to 150 Mbps via the live slider, and at least 150 Mbps under Fast LAN. `DataRateLimits` bound keyframe bursts; under Fast LAN the ceiling is bounded to the receiver's fragment cap so a keyframe cannot overflow reassembly. Every session call (create, encode, property update, invalidate) is serialized behind a recursive lock because `VTCompressionSession` is not safe for concurrent use.

- **HostSession**: Owns the capture/encode/transport wiring and the per-session state machine: the auth handshake, the transport-profile decision (Auto/Resilient/Fast LAN), adaptive bitrate (AIMD on client loss telemetry), region-aware tile-vs-video selection, input dedup, and newest-viewer takeover. Capture is deferred until a client connects and authenticates, and suspended when the viewer goes idle.

- **InputInjector**: Receives normalized (0...1) mouse/keyboard coordinates from the client, maps them to Quartz screen coordinates (respecting `captureBounds` for window/app mode), and injects via `CGEvent.post(tap: .cghidEventTap)`. While a button is held, a move is injected as the matching `.*Dragged` event so drags track the cursor live. Requires Accessibility permission. Skipped on loopback connections to avoid a cursor feedback loop.

### Client side (`LocalCast/Client/`)

- **VideoDecoder**: Parses Annex B NAL units, extracts parameter sets (SPS/PPS for H.264; VPS/SPS/PPS for HEVC), creates a `CMVideoFormatDescription`, and feeds frames to a `VTDecompressionSession`. Once a stream is identified as HEVC, NALs route through the HEVC path (H.264 and HEVC NAL type encodings overlap, so per-NAL guessing would drop HEVC keyframes). Decoded frames are emitted as NV12 (full range) so the renderer can sample the YUV planes directly without a per-frame BGRA conversion. The session is rebuilt when the stream is switched (the client invalidates on stream-switch response).

- **MetalRenderer**: Takes decoded `CVImageBuffer` frames and creates `MTLTexture`s via `CVMetalTextureCache`, selecting the pipeline per frame by pixel format: NV12 full-range frames use a two-plane YUV pipeline with a full-range BT.709 shader (luma `r8`, chroma `rg8`), while BGRA buffers (the region-aware tile/heal path) use the single-texture pipeline. Decoded frames feed an adaptive jitter buffer that releases frames on the measured source interval; the view is display-linked and draws at the hosting screen's maximum refresh (120 on ProMotion), not a fixed 60 fps. Overflow drops to newest; underrun holds the last frame. Inline Metal shaders, no `.metallib` dependency.

- **ClientSession**: Manages the connection lifecycle: DNS resolution via `ConnectionResolver`, the auth handshake, 1 s heartbeats with round-trip latency measurement, keyframe requests, input forwarding, and per-second stream-health telemetry back to the host. Video and tile decode run on a dedicated serial decode queue, off the UDP receive queue, so a large keyframe decode does not stall datagram intake. A two-stage watchdog rides the heartbeat tick: stage 1 (media stalled ~3 s) is non-destructive, surfacing "Reconnecting..." and nudging a keyframe while keeping the session key; stage 2 (sustained total silence ~6 s, keyed sessions only) re-drives the auth handshake to recover from a host settings restart, bounded so a dead host eventually surfaces as disconnected.

### Transport (`LocalCast/Transport/`)

- **UDPTransport**: Apple `Network.framework` based, pinned to IPv4 so the listener and client stay on the same address family. UDP for minimum latency. Packets larger than the payload size are fragmented with a 10-byte header (`frameId`, `fragmentIndex`, `totalFragments`, `payloadLength`); the default payload is 1400 bytes (fits a 1500-byte MTU) and 8900 bytes under jumbo (explicit Fast LAN, needs a 9000-byte MTU). Reassembly uses drop-to-newest: video frames more than the in-flight window behind the newest are abandoned (default window 4 frames, 16 under Fast LAN), with a memory backstop of 120 buffered frames. Optional forward error correction adds two parity fragments (P and Q over GF(256)) per 16-fragment block, letting the receiver reconstruct up to two lost data fragments per block without a retransmit. Large frames are paced in bursts on a dedicated queue (skipped on loopback and Fast LAN). Once a session key is installed the transport rejects any non-encrypted packet; plaintext is accepted only during the pre-key handshake.

- **PacketProtocol**: Simple binary wire format: 1-byte type + 4-byte sequence + 8-byte timestamp (13-byte header) + variable payload. There are 21 packet types covering video, tiles, input, heartbeat, telemetry, the auth handshake, and app-streaming control. `LocalCastClientTelemetry` (loss, FEC recovery, RTT, buffer depth, bitrate) rides the control path about once per second.

### Views (`LocalCast/Views/`)

- **LocalCastViewerWindow**: `NSWindowController` with an `MTKView` wrapped in SwiftUI. Local and global `NSEvent` monitors capture mouse/keyboard and forward as normalized coordinates. Includes a remote app picker overlay for switching streams.

- **LocalCastSettingsView**: Host toggle, live streaming-quality controls, quality preset and codec pickers, streaming-resolution cap, the resilience toggles (adaptive bitrate, drop-to-newest, loss-triggered recovery, FEC), latency mode, transport profile, "Show remote cursor", region-aware streaming, the auth password field and input rate limit, and permission status indicators.

- **StreamingQualityControlView**: The master quality slider (interpolating fps, bitrate, encoder quality, and resolution between the low and ultra extremes) plus per-axis fine-tune overrides, embeddable in the settings pane or the viewer toolbar.

### Core (`LocalCast/Core/`)

- **LocalCastService**: `@MainActor` singleton that manages host and client sessions. Advertises via Bonjour (`dns-sd`, `_tidaldrift-cast._udp`, with codec/fps/auth metadata), handles permissions, applies live and restart-required settings, and exposes `@Published` state for SwiftUI binding. Stores the host password in the Keychain (`LocalCastPasswordStore`).

- **LocalCastConfiguration**: Quality presets (ultra/high/balanced/low), codec selection (default HEVC), frame rate (default 60), capture-dimension cap, latency mode (default Low), transport profile (default Auto), region-aware and FEC toggles, remote-cursor toggle, and the security settings (require authentication, input rate limit). `StreamingTuning` holds the live, continuously adjustable quality values and persists them across a host restart.

- **LocalCastPermissions**: Passive permission checking (`CGPreflightScreenCaptureAccess`) plus on-demand requesting. Separated to avoid the System Settings popup loop encountered during development.

## How it works: the happy path

1. User toggles **Host this Mac** in settings (or the menu-bar LocalCast toggle). This calls `LocalCastService.startHosting()`, which checks Screen Recording permission, starts `HostSession`, and begins listening on UDP port 5904. Capture is deferred until a client connects. Bonjour advertisement goes out via `dns-sd`.

2. Remote TidalDrift discovers the host via the `_tidaldrift-cast._udp` Bonjour service. The device card shows a yellow **LOCALCAST** button.

3. User clicks LOCALCAST. `LocalCastService.connect(to:)` creates a `ClientSession` which resolves the hostname and, if the host advertised auth, runs the handshake; otherwise it goes straight to heartbeats and keyframe requests.

4. Host receives the heartbeat (and, if required, completes auth), starts ScreenCaptureKit, stores the client endpoint, and forces an initial keyframe burst. Encrypted (or, for auth-disabled hosts, plaintext) video frames start flowing to the client over UDP.

5. Client receives frames, decodes via VideoToolbox into NV12, and renders via Metal through the adaptive jitter buffer. The viewer window opens showing the remote screen. The pointer the viewer sees is its own local cursor (the host does not composite its cursor by default), so pointer motion does not round-trip the pipeline.

6. Mouse/keyboard events in the viewer are captured by `NSEvent` monitors, normalized to 0...1 coordinates, serialized, and sent to the host as `inputEvent` packets (clicks and keystrokes sent a few times for reliability, deduplicated host-side by sequence number). The host injects via `CGEvent`.

7. Host-initiated sharing: from the menu-bar share picker the host can switch the live capture between the entire desktop and a single app or window without tearing down the transport (`HostSession.retarget`). The host enumerates shareable apps via `SCShareableContent`. The client-driven in-viewer app picker (`streamAppRequest`) is wired on the host but currently dormant on the viewer side.

## Pixel format: NV12 end to end

The full-frame video path stays in NV12 (`kCVPixelFormatType_420YpCbCr8BiPlanarFullRange`) from capture through decode to render, so there are no BGRA-to-NV12 (encode) or NV12-to-BGRA (decode) conversions on the hot path. ScreenCaptureKit captures NV12, VideoToolbox decodes to NV12, and the renderer samples the two planes directly with a full-range BT.709 shader. The region-aware tile path is the exception: it captures and transports 32BGRA so dirty sub-rects copy tightly packed, and the renderer keeps a BGRA canvas; an NV12 full-frame "heal" is converted to BGRA before it patches that canvas. The renderer picks its pipeline per frame off the incoming pixel format, so a mixed session renders both.

## Security: per-session authentication and encryption

When the host requires authentication, the client and host run a four-message handshake over UDP:

1. **authRequest**: client sends a 32-byte nonce.
2. **authChallenge**: host replies with its own 32-byte nonce plus the AES-256-GCM session key, encrypted under a pairing key.
3. **authComplete**: client derives the same pairing key, decrypts the session key, and returns a proof (the string `AUTH-OK` encrypted under the session key).
4. **authSuccess**: host verifies the proof, installs the session key, and confirms.

The pairing key is derived from the host password and both nonces via HKDF-SHA256; the password never travels over the wire. Once the session key is installed, authentication is effectively per-packet: the transport rejects any non-encrypted packet, so input injection and every other post-auth handler only ever see traffic decrypted under the session key. Plaintext is accepted only during the pre-key handshake (or for sessions that never set a key, i.e. auth disabled). Loopback and idle-timeout transitions re-arm the handshake so a fresh client can authenticate.

Honest limitation: HKDF-SHA256 is a fast key-derivation function, not a slow password hash. It provides domain separation and mixes in the nonces, but it adds no brute-force resistance against a weak password. See "What is next" for the hardening item.

## Transport profiles: Auto, Resilient, Fast LAN

The transport profile (`configuration.transportProfile`, default **Auto**) tunes the link for its conditions:

- **Resilient** is the conservative Wi-Fi profile: paced fragment sends, a tight keyframe `DataRateLimits` cap, and the narrow 4-frame reassembly window. It assumes burst loss on the uplink is the real constraint.
- **Fast LAN** is for a clean wired link. It disables send pacing, loosens the keyframe cap (still bounded to the receiver's fragment cap so a keyframe cannot overflow reassembly), raises the bitrate target (at least 150 Mbps), and widens the reassembly in-flight window to 16 frames. Explicit Fast LAN additionally raises the UDP payload to jumbo (~8900 bytes), which requires a 9000-byte MTU path; jumbo is opt-in for exactly that reason.
- **Auto** starts on the Resilient baseline and promotes to Fast LAN behavior after a sustained run of low-RTT, zero-loss client telemetry, reverting on degradation (rising RTT or any loss), with hysteresis so the choice does not flap. An auto-selected fast link keeps the 1400-byte payload because the path MTU has not been confirmed; only explicit Fast LAN uses jumbo.

## Reliability and latency

These features keep motion smooth and recover quickly on a lossy link; on a clean wired link they have little effect. Each is individually toggleable in settings.

- **Adaptive bitrate** (`adaptiveQuality`, host; on by default via the persisted setting). Clustered client keyframe requests and reported drops are treated as a congestion signal; the encoder bitrate runs AIMD (multiplicative decrease, additive recovery after a quiet period, floor 25%) so motion frames shrink enough to survive, then quality restores.
- **Forward error correction** (`forwardErrorCorrection`, host; off by default). Two parity fragments per 16-fragment block let the receiver reconstruct up to two lost data fragments per block without a retransmit.
- **Latency modes** (`latencyMode`, client; **Low** default). Low keeps the jitter buffer minimal and presents on arrival when there is no backlog; Balanced and Smooth add buffer cushion for jittery links.
- **Drop-to-newest** (`dropToNewest`, client; on by default). Stale, incomplete video frames are abandoned instead of buffering a backlog.
- **Loss-triggered keyframe requests** (`lossRecovery`, client; on by default). An abandoned incomplete frame triggers a keyframe request (rate-limited to one per 300 ms) so the picture heals in roughly one round trip instead of waiting for the scheduled keyframe.
- **Off-queue decode**: video and tile decoding run on a dedicated serial decode queue, so a large keyframe decode does not block the UDP receive queue and manufacture drops.
- **Two-stage viewer watchdog** (see ClientSession): a non-destructive keyframe nudge on a short media stall, escalating to a re-auth after sustained silence so a viewer recovers (for example, after a host settings restart) instead of freezing.

## Local cursor

The host does not composite its cursor by default (`captureCursor` / `showsCursor` is false). The pointer the viewer sees is its own local macOS cursor, which removes the capture/encode/decode round trip from pointer motion. The **Show remote cursor in stream** setting re-enables host-side cursor compositing for view-only sessions where the client should follow the host user's pointer; it applies live on macOS 14+ and otherwise on the next session.

## Loopback demo mode

For development and demos, a **loopback device** (127.0.0.1) can be added via Add Device > Add Loopback Device (DEBUG builds only). This exercises the full pipeline on a single machine:

- Video: capture -> encode -> UDP -> decode -> Metal render
- Input: event capture -> serialize -> UDP -> deserialize (injection skipped on loopback to avoid cursor feedback)

Pacing is bypassed on loopback (there is no uplink to overrun, and the gaps only add latency).

## Build and run

```bash
cd TidalDrift
bash build-app.sh           # Build, sign, DMG, install to /Applications, launch
bash build-app.sh --no-run  # Build only, do not launch
```

The build script:
- Builds with Debug configuration (includes loopback and dev features)
- Signs with your Developer ID certificate (stable Screen Recording permissions)
- Creates a DMG in `dist/`
- Installs to `/Applications` and launches

## Key decisions and tradeoffs

**UDP over TCP.** UDP was chosen for the video transport because TCP's congestion control and retransmission add latency worse than dropping a frame. A lost fragment discards its frame; the next keyframe (1.5 s interval by default) resyncs, and FEC plus loss-triggered keyframe requests shorten that gap further. Input events are also UDP; clicks and keystrokes are sent a few times and deduplicated host-side so a single drop does not lose them.

**NV12 over BGRA on the video path.** Keeping capture, decode, and render in NV12 avoids two per-frame color conversions and keeps the IOSurface zero-copy into VideoToolbox and Metal. The cost is a YUV-to-RGB shader on the client, which is cheap on the GPU.

**Annex B over AVCC.** VideoToolbox outputs AVCC (length-prefixed NAL units), but the pipeline converts to Annex B (start-code delimited) on the wire. This makes the stream self-describing: the decoder can find NAL boundaries without out-of-band signaling, and parameter sets are inline with keyframes.

**Inline Metal shaders.** Shaders are compiled from source strings at init time rather than shipped as a `.metallib`. This avoids SPM resource bundling issues and ensures the renderer works in any build configuration.

**1400-byte fragment size.** Chosen to stay under a typical 1500-byte MTU with room for IP/UDP headers (8900 under jumbo). Keyframes can be large; quality-focused 4K encoding can produce 2-5 MB keyframes, which at ~1390 payload bytes per fragment is on the order of thousands of fragments (the receiver caps reassembly at 5000 fragments per frame). Reassembly is frame-ID based with drop-to-newest pruning.

**No audio (yet).** `LocalCastConfiguration.captureAudio` exists but is set to `false`. ScreenCaptureKit supports audio capture; wiring it through is straightforward but was not needed for the initial release.

## Permissions

- **Screen Recording**: Required for `SCStream`. Checked via `CGPreflightScreenCaptureAccess()`, requested via `CGRequestScreenCaptureAccess()` only on explicit user action.

- **Accessibility**: Required for `CGEvent.post()` input injection. Optional for streaming-only use. Checked via `AXIsProcessTrusted()`.

- **Local Network**: Required for Bonjour discovery and UDP transport. Declared in `Info.plist` via `NSLocalNetworkUsageDescription` and `NSBonjourServices`.

## What is next

- Audio capture and forwarding
- Stronger password key derivation: the pairing key currently uses HKDF-SHA256, which is fast by design and not a brute-force-resistant password hash. A slow, memory-hard KDF (for example scrypt or Argon2) over the password would harden weak passwords against offline guessing.
- Re-enabling the client-driven in-viewer app picker (the host side already handles `streamAppRequest`)
- Clipboard sync during LocalCast sessions
- File drop into the viewer window
