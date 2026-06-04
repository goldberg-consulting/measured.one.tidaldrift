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

### Plan

- Reduce `queueDepth` (done: 5 → 3) to trim worst-case buffering.
- **Next: client-side drop-to-newest** so a backlog self-corrects.
- Lower the default bitrate / wire up real adaptive bitrate that backs off under
  loss (the `adaptiveQuality` flag is not yet acted on).
- Consider FEC or selective retransmit for keyframes on lossy links.

### Calibration

Before deeper transport work, isolate Wi-Fi from our buffering: drag the viewer
quality slider to **Low** (if lag drops sharply, it's bandwidth) and/or connect
the two Macs over **Ethernet** (if it gets crisp, it's Wi-Fi). The wired result
tells us how much budget is the link versus the pipeline.
