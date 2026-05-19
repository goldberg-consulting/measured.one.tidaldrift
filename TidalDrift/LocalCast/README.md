# TidalCast: Screen and App Streaming for macOS

> **Status:** TidalCast's full-desktop VNC streaming (Tier 1) is fully functional. App-window streaming (Tier 2) is **not yet fully implemented**. The custom pipeline described below is architecturally complete and the code compiles and runs, but app-window streaming has known limitations around window eligibility, failure diagnostics, and cross-machine reliability. Contributions are welcome.

TidalCast is TidalDrift's streaming engine with a two-tier architecture:

## Tier 1: Full Desktop (VNC)

Full-desktop sharing uses **macOS built-in Screen Sharing** (`vnc://`). Apple handles encoding, compression, input forwarding, clipboard sync, and authentication natively. No custom code is required; TidalDrift opens the URL directly.

## Tier 2: App/Window Streaming (this code)

For streaming a **single app or window** as a native-looking client window, TidalCast employs a custom pipeline built on Apple's low-level frameworks. The client picks an app from the host's window list, the host captures that window via ScreenCaptureKit, encodes it with VideoToolbox, and sends it over UDP. The client decodes and renders in a Metal-backed NSWindow.

## Why the custom pipeline exists

VNC shares the entire desktop. When the goal is to treat a remote app as if it were running locally, with its own window, its own title bar, and input scoped to that window, per-window capture and rendering are required. macOS provides the building blocks (ScreenCaptureKit, VideoToolbox, Metal) but does not expose per-window VNC. TidalCast wires them together.

## Architecture

The pipeline runs in-process. No external daemons, no ffmpeg, no GStreamer. Five components, each under 500 lines:

```
┌─────────────────────── HOST ────────────────────────┐
│                                                     │
│  ScreenCaptureKit ──▶ VideoEncoder ──▶ UDPTransport │
│  (SCStream)           (VTCompression     (NWListener│
│                        H.264/HEVC)        + frag)   │
│                                                     │
│  InputInjector ◀── UDPTransport (receive)           │
│  (CGEvent.post)                                     │
└─────────────────────────────────────────────────────┘
                         ▲  UDP :5904  ▼
┌─────────────────────── CLIENT ──────────────────────┐
│                                                     │
│  UDPTransport ──▶ VideoDecoder ──▶ MetalRenderer    │
│  (NWConnection      (VTDecompression    (MTKView    │
│   + reassembly)      H.264/HEVC)        + shaders)  │
│                                                     │
│  Event monitors ──▶ UDPTransport (send)             │
│  (NSEvent)            normalized coords             │
└─────────────────────────────────────────────────────┘
```

### Host side (`LocalCast/Host/`)

- **ScreenCaptureManager**: Wraps ScreenCaptureKit's `SCStream`. Supports three capture modes: full display, single window, single app. Delivers `CMSampleBuffer` frames to the encoder via delegate.

- **VideoEncoder**: Creates a `VTCompressionSession` (H.264 or HEVC), converts output from AVCC to Annex B format, and prepends SPS/PPS on keyframes. Real-time encoding at configurable bitrate (15--100 Mbps) and frame rate.

- **InputInjector**: Receives normalized (0...1) mouse/keyboard coordinates from the client, maps them to screen coordinates (respecting capture bounds for window/app mode), and injects via `CGEvent.post(tap: .cghidEventTap)`. Requires Accessibility permission. Automatically skipped on loopback connections to avoid cursor feedback loops.

### Client side (`LocalCast/Client/`)

- **VideoDecoder**: Parses Annex B NAL units, extracts SPS/PPS/VPS parameter sets, creates `CMVideoFormatDescription`, and feeds frames to a `VTDecompressionSession`. Handles both H.264 and HEVC. Auto-recreates the session on resolution changes (e.g., when switching from full-display to app-specific streaming).

- **MetalRenderer**: Takes decoded `CVImageBuffer` frames, creates `MTLTexture` via `CVMetalTextureCache`, and renders a full-screen textured quad with aspect-ratio-preserving scaling. Inline Metal shaders (no .metallib dependency). 60fps draw loop.

- **ClientSession**: Manages the connection lifecycle: DNS resolution via `ConnectionResolver`, heartbeat keep-alive, keyframe requests, input forwarding, and remote app streaming commands.

### Transport (`LocalCast/Transport/`)

- **UDPTransport**: Apple `Network.framework` based. UDP for minimum latency. Packets larger than 1200 bytes are fragmented with a 10-byte header (`frameId + fragmentIndex + totalFragments + payloadLength`). Reassembly buffer holds the last 100 frame IDs.

- **PacketProtocol**: Simple binary wire format: 1-byte type + 4-byte sequence + 8-byte timestamp + variable payload. Ten packet types cover video, input, heartbeat, stats, and app-streaming control.

### Views (`LocalCast/Views/`)

- **LocalCastViewerWindow**: `NSWindowController` with an `MTKView` wrapped in SwiftUI. Local and global `NSEvent` monitors capture mouse/keyboard and forward as normalized coordinates. Includes a remote app picker overlay for switching streams.

- **LocalCastSettingsView**: Quality preset picker, codec selector, permission status indicators.

### Core (`LocalCast/Core/`)

- **LocalCastService**: Singleton that manages host and client sessions. Advertises via Bonjour (`dns-sd`), handles permissions, and exposes `@Published` state for SwiftUI binding.

- **LocalCastConfiguration**: Quality presets (ultra/high/balanced/low), codec selection, frame rate, adaptive quality toggle.

- **LocalCastPermissions**: Passive permission checking (`CGPreflightScreenCaptureAccess`) plus on-demand requesting. Separated to avoid the System Settings popup loop encountered during development.

## How it works: the happy path

1. User toggles **Screen Streaming** ON in the sidebar. This calls `LocalCastService.startHosting()`, which checks screen capture permission, starts `ScreenCaptureManager` + `VideoEncoder`, and begins listening on UDP port 5904. Bonjour advertisement goes out via `dns-sd`.

2. Remote TidalDrift discovers the host via `_tidaldrift-cast._udp` Bonjour service. The device card shows a yellow **LOCALCAST** button.

3. User clicks LOCALCAST. `LocalCastService.connect(to:)` creates a `ClientSession` which resolves the hostname, starts heartbeats, and requests keyframes.

4. Host receives heartbeat, stores client endpoint, and forces a keyframe. Encoded video frames start flowing to the client over UDP.

5. Client receives frames, decodes via VideoToolbox, and renders via Metal. The viewer window opens showing the remote screen.

6. Mouse/keyboard events in the viewer are captured by `NSEvent` monitors, normalized to 0...1 coordinates, serialized, and sent to the host as `inputEvent` packets. The host deserializes and injects via `CGEvent`.

7. User can click **Apps** in the viewer toolbar to browse remote apps. The host enumerates running apps via `SCShareableContent` and sends the list. Clicking an app sends a `streamAppRequest`; the host stops the current capture and starts a new one targeting that app.

## Loopback demo mode

For development and demos, a **loopback device** (127.0.0.1) can be added via Add Device > Add Loopback Device (DEBUG builds only). This exercises the full pipeline on a single machine:

- Video: capture -> encode -> UDP -> decode -> Metal render
- Input: event capture -> serialize -> UDP -> deserialize (injection skipped on loopback to avoid cursor feedback)
- App switching: full display to specific app

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

**UDP over TCP.** UDP was chosen for the video transport because TCP's congestion control and retransmission add latency worse than dropping a frame. Lost fragments result in a dropped frame; the next keyframe (approximately every 1 second) resyncs. Input events are also UDP (fire-and-forget), which is acceptable for mouse moves. Clicks could theoretically be lost, but on a LAN this does not occur in practice.

**Annex B over AVCC.** VideoToolbox outputs AVCC (length-prefixed NAL units), but the pipeline converts to Annex B (start-code delimited) on the wire. This makes the stream self-describing: the decoder can find NAL boundaries without out-of-band signaling, and SPS/PPS are inline with keyframes.

**Inline Metal shaders.** Shaders are compiled from source strings at init time rather than shipped as a `.metallib`. This avoids SPM resource bundling issues and ensures the renderer works in any build configuration.

**1200-byte fragment size.** Chosen to stay under typical MTU (1500) with room for IP/UDP headers. Larger frames (keyframes can exceed 300 KB) are split into approximately 250 fragments. Reassembly is frame-ID based with a 100-frame LRU.

**No audio (yet).** `LocalCastConfiguration.captureAudio` exists but is set to `false`. ScreenCaptureKit supports audio capture; wiring it through is straightforward but was not needed for the initial release.

## Permissions

- **Screen Recording**: Required for `SCStream`. Checked via `CGPreflightScreenCaptureAccess()`, requested via `CGRequestScreenCaptureAccess()` only on explicit user action.

- **Accessibility**: Required for `CGEvent.post()` input injection. Optional for streaming-only use. Checked via `AXIsProcessTrusted()`.

- **Local Network**: Required for Bonjour discovery and UDP transport. Declared in `Info.plist` via `NSLocalNetworkUsageDescription` and `NSBonjourServices`.

## What is next

- Audio capture and forwarding
- Latency measurement from heartbeat RTT
- Adaptive bitrate based on packet loss
- Clipboard sync during LocalCast sessions
- File drop into the viewer window
