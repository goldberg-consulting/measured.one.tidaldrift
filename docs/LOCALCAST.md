# LocalCast (Metal Streaming): Pipeline, Input, and Latency

**Scope:** How the LocalCast screen-streaming path works, the reliability/input
fixes landed in 1.6.x, and where latency actually comes from.

---

## Pipeline (fully GPU / hardware accelerated)

| Stage | Tech | Notes |
|---|---|---|
| Capture (host) | ScreenCaptureKit | IOSurface-backed frames from the window server; no CPU readback |
| Encode (host) | VideoToolbox `VTCompressionSession` (H.264/HEVC) | Apple-silicon **hardware** encoder; `RealTime = true`, `MaxFrameDelayCount = 0` |
| Transport | UDP (`NWListener`/`NWConnection`), app-level fragmentation | ~1400-byte fragments; AES-256-GCM when auth is on |
| Decode (client) | VideoToolbox `VTDecompressionSession` | **hardware** decoder; output is Metal-compatible |
| Render (client) | `CVMetalTextureCache` + `MTKView` | **zero-copy** `CVPixelBuffer` → `MTLTexture`; draw-on-demand |

The whole chain is hardware-accelerated, which is why TidalDrift sits near
**0% CPU** while streaming. The GPU/codec is not the bottleneck.

## Reliability and input fixes (1.6.x)

- **IPv4 transport pin (1.6.10).** `NWListener` could bind the host port
  IPv6-only while clients resolve hosts to IPv4 (`AF_INET`), so the host
  received nothing and the client showed "no response from host." The UDP
  transport now pins `NWProtocolIP.Options.version = .v4` on both ends.
- **Auth in the menu + pre-auth heartbeats (1.6.11).** The require-password /
  host-password controls were hidden in a Settings sub-tab (behind the tab
  overflow). They are now in the dropdown's hosting section. Separately, a host
  that requires a password used to drop the client's heartbeats until
  authenticated, which surfaced as a misleading "no response from host"; the
  host now answers heartbeats pre-auth (video stays gated) so the failure is
  recognizably about auth, not the network.
- **Input coordinate normalization (1.6.12).** The viewer normalized mouse
  coordinates against the whole content view, but the renderer
  letterboxes/pillarboxes the stream to preserve aspect ratio, so clicks landed
  offset from the cursor (worst on single-window streaming). Input is now mapped
  to the actual aspect-fit video rect and clamped to [0,1] (so a mouse-up on a
  bar can't leave a stuck button). Keyboard modifiers are masked to
  `deviceIndependentFlagsMask` so shift/control/option/command (e.g. copy/paste
  on the remote) map cleanly to `CGEventFlags`.
- **Capture-start race + viewer takeover (earlier 1.6.x).** Capture starts once
  per connected client (no duplicate `SCStream`s), and the newest viewer takes
  over as the single active client.
- **Live drag tracking (1.6.18).** While a button is held, a move is a *drag*:
  AppKit's window/selection tracking loops consume `.leftMouseDragged`, not
  `.mouseMoved`. The injector now tracks the held button and emits the matching
  dragged event, so dragging a window follows the cursor live instead of
  jumping to the drop point. (The client already sends moves during
  `.leftMouseDragged`; the gap was host-side injection.)
- **Live quality change froze the viewer (1.6.18).** `SCStream.updateConfiguration`
  replaces the *entire* configuration, but the frame-rate update passed a bare
  `SCStreamConfiguration` (width/height/pixelFormat all default), resetting the
  stream to 0x0 and freezing the viewer until a re-share rebuilt it. The capture
  manager now retains the active config and mutates only the frame interval (and
  skips the call when fps is unchanged); the host also forces a keyframe after a
  live quality change so the viewer resyncs immediately.
- **Render tearing / typing shear (1.6.18).** The Metal renderer kept the
  `MTLTexture` but not the `CVImageBuffer`/`CVMetalTexture` backing it, so
  VideoToolbox could recycle that IOSurface for a later frame and the GPU would
  sample a buffer mid-overwrite (shear, worst during rapid small updates like
  typing). The renderer now retains the current buffer and wrapper, and extends
  their lifetime through the GPU draw via the command-buffer completion handler.

Coordinate model: the client sends normalized `(x, y)` with a top-left origin
relative to the video. The host maps them with `InputInjector`:
`captureBounds` (the window/app frame in Quartz coords) for window/app capture,
or `CGDisplayBounds(CGMainDisplayID())` for full desktop. Both are top-left
origin, matching `CGEvent`.

## Diagnosing the link: peer speed test (1.6.14)

Device Details has a **Network Speed Test** (UDP/IPv4, same family as the
stream) that reports RTT/jitter, down/up throughput, and **packet loss** in each
direction. Loss is the metric that matters: UDP has no retransmit, so a lossy
direction breaks frames regardless of raw Mbps.

Measured Air ↔ Pro on Wi-Fi (1.6.15): download 746 Mbps / 0% loss, but a
saturating **upload burst shed ~13%** of its packets at 349 Mbps. Bandwidth is
not the constraint; **burst loss on the host's uplink** is. That directly
implicates keyframe sends, which are exactly such bursts.

**Apply optimized settings (1.6.22):** after a test, Device Details shows a
recommendation derived from the measured link (`SpeedTestService.recommend`) and
an "Apply optimized settings" button that writes the `localCast*` defaults
(resolution, region-aware, adaptive, drop-to-newest, loss recovery, codec).
Resolution and codec scale with the constrained-direction bandwidth; region-aware
turns on for lossy/low-bandwidth links; resilience options stay on (no-ops on a
clean link). Applies on the next session.

## Latency: where it comes from

Latency is dominated by the **link and the transport**, not the GPU:

1. **Burst loss on big frames.** A keyframe is hundreds of UDP fragments. Handed
   to the stack in one tight loop, they overrun the Wi-Fi uplink and ~13% are
   dropped (measured). With no FEC/retransmit, losing one fragment makes the
   whole frame undecodable and the client stalls to the next keyframe. **Fixed
   in 1.6.16** (see below).
2. **Wi-Fi bandwidth vs bitrate.** Bitrate above the link's comfortable rate
   over **UDP with no congestion control** adds queuing delay and loss. (On the
   tested LAN there is ample bandwidth; this is secondary.)
3. **Capture buffering.** `SCStreamConfiguration.queueDepth` adds buffered
   frames ahead of the encoder.
4. **No client catch-up.** The client does not skip to the newest frame when it
   falls behind.

### Fix 1: paced fragment sending (1.6.16)

`UDPTransport.sendFragmented` no longer dumps every fragment of a large frame
into the stack at once. Frames above a small threshold are drained on a
dedicated queue in bursts of `pacingBatchSize` separated by `pacingGapMicros`,
keeping the instantaneous send rate (~256 Mbps ceiling) under the uplink's
capacity. Small frames (≤ `pacingFragmentThreshold` fragments) still send
immediately, so pacing adds no latency where it isn't needed. This targets the
~13% burst loss directly. Constants live at the top of `UDPTransport` for tuning
against speed-test numbers.

### Fix 2: loss resilience bundle (1.6.17)

A symptom report crystallised the remaining problem: when dragging, interim
frames vanish (low effective fps) while still frames are crisp. Cause: a motion
frame is a large delta of 100+ fragments, and with no FEC/retransmit one lost
fragment kills the whole frame. Static frames are a few fragments and almost
always arrive; motion frames frequently lose one and are dropped. (macOS Screen
Sharing makes the opposite trade: it softens during motion to hold frame rate.)

Four complementary changes, each individually toggleable in Metal Streaming
settings:

- **Adaptive bitrate (`localCastAdaptive`, host).** The client requests a
  keyframe on every abandoned-incomplete frame; the host treats clustered
  requests as congestion and runs AIMD on the encoder bitrate
  (`adaptiveScale`, ×0.8 down rate-limited, +0.1 up after a quiet period, floor
  25%). Motion frames shrink enough to survive, then quality restores. A
  post-connect grace window ignores the connect-time keyframe requests.
- **Drop-to-newest (`localCastDropToNewest`, client).** Reassembly abandons
  frames that fall behind the newest by more than `inFlightFrameWindow` instead
  of buffering a long backlog, and ignores stragglers for abandoned frames.
- **Loss-triggered recovery (`localCastLossRecovery`, client).** An abandoned
  incomplete frame fires `udpTransportDidLoseFrames`; the client requests a
  keyframe (rate-limited to 1/300 ms) so the picture heals in ~1 RTT instead of
  waiting for the scheduled IDR.
- **Shorter keyframe interval (4 s → 1.5 s, host).** Bounds worst-case recovery;
  pacing keeps the more frequent keyframes from re-introducing burst loss.

### Resolution control (1.6.17)

`LocalCastConfiguration.maxDimensionOverride` (UI: "Streaming resolution",
`localCastMaxDimension`) caps the captured frame's longest edge, aspect ratio
preserved. `0` = Native, which streams the full panel resolution including
ultrawide (5120x1440). Options: Native / 720p / 1080p / 1440p / 4K / Ultrawide.

### Fix 3: adaptive jitter buffer + render pacing (1.6.19)

Even with loss handled, motion looked less smooth than macOS Screen Sharing
because the client presented each decoded frame the instant it arrived. With
±30-40 ms link jitter, frames land in clumps, so playback cadence was uneven.

`MetalRenderer` now queues decoded frames and releases them on a steady,
time-based cadence (the measured source interval, `arrivalIntervalEWMA`),
decoupled from both bursty arrival and the display refresh rate. The buffer is
display-linked (`isPaused = false`) rather than draw-on-demand so it has a tick
to pace against. Depth is adaptive: `targetDepth = round(jitter / interval) + 1`,
clamped to `[1, 6]`, so a jittery link gets cushion while a clean link stays near
one frame of latency. Overflow drops to newest; underrun re-buffers and holds the
last frame. Each queued frame retains its `CVImageBuffer`/`CVMetalTexture` (and is
held through the GPU draw), preserving the tearing fix.

### Fix 4: region-aware streaming (experimental, 1.6.20)

Full parity step toward Screen Sharing: send only what changed. Toggle in
Metal Streaming settings ("Region-aware streaming"), host-side, default off.

- Host reads `SCStreamFrameInfo` dirty rects ([ScreenCaptureManager](../TidalDrift/LocalCast/Host/ScreenCaptureManager.swift)).
  Small changed area -> crop the dirty bounding box and send it as a lossless
  LZFSE BGRA tile (`tileUpdate` packet, [TileCodec](../TidalDrift/LocalCast/Core/TileCodec.swift));
  large change -> fall back to full-frame video. Hysteresis
  (`regionTileMaxCoverage` / `regionVideoCoverage` / streak) avoids flapping.
- Client keeps a persistent canvas texture ([MetalRenderer](../TidalDrift/LocalCast/Client/MetalRenderer.swift)):
  tiles blit into sub-rects, full frames replace it, the canvas is presented
  each display tick. Activated on the first tile, so the default jitter-buffer
  path is unchanged.
- Recovery (chosen: periodic + on-request full refresh): the host sends a full
  frame every ~4 s, on client `keyframeRequest`, and at viewer connect to seed
  the canvas. A lost tile heals at the next refresh.
- Transport: the top frameId bit marks droppable (video) frames; drop-to-newest
  reassembly only discards those, so tiles are never dropped as "stale"
  ([UDPTransport](../TidalDrift/LocalCast/Transport/UDPTransport.swift)).
- Codec: HEVC selectable for the full-frame fallback. The decoder routes NALs by
  codec once HEVC is detected (HEVC IDR type 19 otherwise collided with H.264
  SEI type 6 and was dropped). Default remains H.264 pending two-Mac validation.

Why not pure "small change = small data": H.264/HEVC P-frames already delta-code,
so typing is already a small frame. Region-aware's wins are avoiding full-frame
keyframes, not re-encoding the whole panel every tick (ultrawide), and
lowest-latency localized updates.

### Fix 5: forward error correction (FEC, experimental, 1.6.30)

The Moonlight/Sunshine borrow: recover lost UDP packets without a retransmit.
Toggle in Metal Streaming settings ("Forward error correction"), host-side,
default off. Both Macs should be updated.

- Sender ([UDPTransport.sendFragmented](../TidalDrift/LocalCast/Transport/UDPTransport.swift)):
  for droppable (video) frames, after each block of `fecBlockSize` (16) data
  fragments, emit one parity fragment = XOR of the block's payloads zero-padded
  to the fragment payload size. Parity reuses the 10-byte header with the high
  bit of `fragmentIndex` set, so the wire format is unchanged for peers that
  don't understand FEC. Parity is interleaved after its block and paced with it.
- Receiver: parity is stored in a separate `parityBuffers` (never counted toward
  completion). `recoverBlock` reconstructs a single missing data fragment per
  block via XOR, except the frame's last (short) fragment whose length can't be
  inferred. Recovery is always attempted regardless of the local toggle.
- Why XOR not Reed-Solomon: XOR recovers exactly one loss per block, which is
  the common Wi-Fi pattern, with ~6% overhead and no new dependency. If the
  stats HUD's "Recovered/s" is high but "Dropped/s" stays non-zero (multiple
  losses per block), move to multi-parity Reed-Solomon (Phase 1b).
- Stats: the HUD now shows "Recovered/s" (`fecRecoveredPerSec`).

Codec note for AV1: M3/M4 can hardware-*decode* AV1 (see the Moonlight/
Jellyfin-ffmpeg builds), but Apple Silicon has no hardware AV1 *encoder* exposed
to VideoToolbox, and software AV1 is too slow for interactive Mac-to-Mac. HEVC
remains the target codec; AV1 is a deferred research spike, not a dependency.

### Plan (remaining, toward Screen-Sharing parity)

The user's target is full parity: adaptive buffering (done), region-aware updates
(done, experimental, above), plus **reliable transport**. Sequencing and tradeoffs:

- **Reliable transport.** Options, lowest-risk first: (a) FEC/parity on keyframes
  over the existing UDP (recover lost fragments without a round trip, keeps low
  latency); (b) selective NACK retransmit; (c) a full TCP transport mode (simplest
  reliability, but head-of-line blocking adds latency under loss, and it partly
  undoes the UDP/pacing work). Recommend (a) before (c).
- **Region-aware updates.** Send only changed regions instead of full-frame video.
  This is a large rework that converges on what the existing VNC tier already
  does; for a buttery *full desktop*, the VNC path is the better tool, with
  LocalCast focused on high-fidelity single app/window streaming.
- Reduce `queueDepth` (done: 5 → 3) to trim capture-side buffering.
- Separate the input/heartbeat channel from video to avoid head-of-line blocking
  under a video burst.

### Calibration

Before deeper transport work, isolate Wi-Fi from our buffering: drag the viewer
quality slider to **Low** (if lag drops sharply, it's bandwidth) and/or connect
the two Macs over **Ethernet** (if it gets crisp, it's Wi-Fi). The wired result
tells us how much budget is the link versus the pipeline.
