# LocalCast engineering and validation guide

Reviewed 2026-09-07. This document describes the current source tree. It does
not certify a released build or claim that LocalCast outperforms Apple Screen
Sharing. The separate system Screen Sharing option remains available.

## Streaming contract

LocalCast captures a desktop, app, or window on the host and presents it in a
native viewer window. One active viewer controls each host session. Host
Screen Recording permission enables capture; Accessibility enables injected
input. Local Network permission and network/firewall reachability are required
for discovery and direct connections.

The default full-frame path is:

1. ScreenCaptureKit supplies IOSurface-backed NV12 frames.
2. VideoToolbox encodes H.264 or HEVC using a **required hardware encoder**.
3. UDP transport encrypts authenticated-session packets, fragments frames,
   paces bursts, and optionally adds forward error correction.
4. VideoToolbox decodes complete compressed access units using a **required
   hardware decoder**, emitting Metal-compatible NV12 buffers.
5. Metal samples the retained IOSurface textures and converts YUV for display.

Hardware media engines perform encode/decode; the GPU performs presentation
and color conversion. CPU work remains in packet handling, encryption,
reassembly, input, and clipboard operations. Experimental region tiles also
use CPU copies and LZFSE compression. There is no supported “0% CPU” claim,
and region-aware mode is not an entirely GPU-based pipeline.

HEVC is preferred. Encoder creation retries without the optional low-latency
rate controller, then falls back to hardware H.264 if HEVC is unavailable.
Software codecs are not a fallback. Hardware initialization failure is reported
with guidance to select H.264 or reduce resolution. Metal initialization
failure prevents the viewer connection. Both Macs need compatible hardware.

The decoder detects codec changes from parameter sets and submits all slices
of a frame together. It can retry a failed session creation. The renderer
uses pixel-buffer range and matrix metadata for conversion and retains buffers
through GPU completion. This is an 8-bit, 4:2:0 SDR video path, not a 4:4:4 or
HDR reference workflow.

## Settings and recovery

- **Bitrate, frame rate, and encoder quality:** live updates. Validated requested
  values persist across capture rebuilds. Congestion and thermal policies can
  reduce the actual values; they recover toward the requested bitrate.
- **Codec, resolution, and region-aware mode:** capture/encoder rebuild within
  the existing authenticated session. The listener, encryption key, and
  clipboard channel remain alive. A brief held frame is expected during the
  rebuild. Changes coalesce for roughly 600 ms and finish even if Settings
  closes. A capture failure is reported and uses the bounded recovery path.
- **Resolution:** Automatic follows the quality slider; Native imposes no
  configured cap. A named host cap replaces Automatic. An explicit viewer
  resolution override takes precedence. Changing the host resolution picker
  clears the host's local tuning override. All caps preserve aspect ratio;
  transport-capacity recovery can lower the effective resolution.
- **Adaptive bitrate, FEC, transport profile, cursor capture, thermal policy:**
  apply to hosting without dropping the session. Fast LAN changes pacing and
  buffering; selecting it alone never assumes a jumbo-frame network.
- **Viewer latency mode, drop-to-newest, loss recovery:** apply on the next
  viewer connection, as the settings help states.
- **Password, authentication, input rate limit:** apply after stopping and
  starting hosting. Required authentication without a password refuses to
  start. Disabling authentication explicitly permits unencrypted control/video;
  clipboard synchronization requires an authenticated session.
- **Initial quality preset:** initializes tuning when saved live tuning is
  absent. Existing saved tuning is retained.

Capture transitions serialize stop/start work. Stopped sessions reject late
capture-start callbacks. Display changes and capture failures rebuild the
selected target; an invalid app/window request never falls back to revealing
the whole desktop. A dead network listener or a system wake needs a full host
restart and client reauthentication. Settings changes use the lighter capture
path.

Video loss triggers a keyframe request; optional FEC reconstructs up to two
missing full-size data fragments per block. It cannot recover the short final
fragment without its length. There is no selective video retransmission or
reliable control acknowledgement protocol. UDP recovery is bounded and cannot
guarantee uninterrupted pictures on arbitrary loss or network outages.

## Discovery and clipboard

LocalCast advertises `_tidaldrift-cast._udp` on UDP 5904. Its TXT data includes
connection metadata and an address hint. Advertisement health is monitored
and refreshed after address changes. Discovery data identifies candidates;
it is not cryptographic proof of identity. Consult [Bonjour discovery](BONJOUR_DISCOVERY.md)
for DNS deadlines, service ports, fallback, and limitations.

Clipboard updates are bidirectional for supported plain/rich text, HTML,
images, and regular files. Small messages use session UDP; larger payloads
and files use an authenticated TCP bulk channel on port 5906. Files download
on paste through file promises. LocalCast deliberately does not copy every
pasteboard format, folder, file attribute, or privacy-sensitive item. See
[clipboard sync](CLIPBOARD_SYNC.md) for exact limits and retry semantics.

## Comparison with Apple Screen Sharing

Use both Apple **Standard** and **High Performance** as explicit baselines.
Apple documents High Performance support for stereo audio, HDR reference mode,
4:4:4 chroma, and 30/60 fps low-latency streaming on supported Apple-silicon Macs.
See [Apple's screen sharing modes](https://support.apple.com/guide/mac-help/screen-sharing-type-options-on-mac-mchl1883115d/mac)
and [clipboard and screen sharing controls](https://support.apple.com/guide/mac-help/share-the-screen-of-another-mac-mh14066/mac).

LocalCast currently lacks audio, HDR/4:4:4, and full clipboard/file semantics
parity. Its GPU-backed design alone is not evidence of lower latency, better
compression, or better perceived quality. The UI latency statistic measures
heartbeat **network round-trip time**, not input-to-photon or capture-to-display
latency. FPS measures received media activity, not guaranteed displayed frames.

## Reproducible acceptance procedure

For release hardware verification, run
`LOCALCAST_REQUIRE_HARDWARE_TESTS=1 swift test -c release` from `TidalDrift`.
This requires real H.264/HEVC round trips, codec/resolution recovery, and
an IOSurface NV12 4K benchmark. The benchmark submits a static synthetic image
with at most three outstanding pictures; it excludes capture, network, and
presentation latency. On the shared M5 test Mac, September 7 measurements
varied roughly 55–66 fps. Repeated strict 60-fps checks failed under concurrent
video load, so sustained 4K60 is not certified. Set `LOCALCAST_MIN_4K_FPS=60`
in addition to the hardware flag for a controlled idle-machine capacity gate.

The low-latency hardware encoder can return `kVTPropertyNotSupportedErr` for
the optional hardware-status query. Successful creation with
`RequireHardwareAcceleratedVideoEncoder` already forbids software fallback;
an unsupported diagnostic no longer causes a working encoder to be rejected.

Record application revision, both Mac models/chips, macOS versions, display
resolution/refresh/scaling, codec, all tuning overrides, network interfaces,
link speed/MTU, and power/thermal state. Update both Macs to the same build.
Use dedicated test content and empty test clipboards.

Run each scenario against LocalCast, Apple Standard, and Apple High Performance
where supported, at matched resolution and frame rate. Repeat at least three
times after warm-up. Report raw samples, median, p95, worst case, and failures.
Do not substitute a throughput benchmark or ping for video measurements.

1. **Input-to-photon:** film a locally visible input trigger and its remote
   response with a high-speed camera or equivalent synchronized hardware.
   Include typing, scrolling, window dragging, and animated content.
2. **Image quality and compression:** use static small text, colored text,
   gradients, photographs, and motion. At matched bitrate compare captures
   against source frames, including chroma-detail crops. At matched visual
   quality compare measured wire bitrate. Record actual codec and resolution,
   including hardware fallback and capacity reductions.
3. **Presentation:** record delivered frame intervals, dropped frames, startup
   time, static-frame behavior, CPU/GPU/media-engine load, memory growth, and
   temperature over a 30-minute session. Include full-screen transitions,
   occlusion/minimize, display migration, and 60/120 Hz viewers.
4. **Settings recovery:** repeatedly change H.264/HEVC, resolution, region mode,
   bitrate, FPS, FEC, and transport profile while streaming and copying a file.
   Close Settings immediately after each edit. Verify the selected target,
   authentication, file transfer, input mapping, and requested tuning survive.
   Suggested release gate: no disconnect and first fresh frame within two
   seconds for supported settings on a stable wired link.
5. **Network recovery:** test normal Ethernet MTU 1500, Wi-Fi, 0.1/1/3% random
   loss, short loss bursts, interface changes, DHCP renewal, sleep/wake, and
   listener failure. Measure recovery instead of claiming a fixed guarantee.
   Reconnect after a host restart and confirm clipboard and input resume.
6. **Clipboard:** both directions, text/RTF/HTML, PNG/TIFF, multiple regular
   files, empty files, exactly-at-limit and over-limit payloads. Copy B while A
   downloads; stop or disable sync during transfer; paste a file twice; cancel
   and retry. A stale completion must never replace B or write after stop.
7. **Privacy/failure:** missing password, wrong password, revoked permissions,
   closed shared window, unavailable hardware codec, and malformed peer data.
   Failure must explain the problem without widening the shared target.

Automated tests cover deterministic contracts; the matrix above remains a
release gate requiring two Macs and real displays. No measurements from this
matrix have been collected as part of this source review.

### Viewer interaction regression checks

The viewer uses a normal title bar and makes TidalDrift a regular application
while any viewer is open. Closing the last viewer restores the prior menu-bar
activation policy. Cmd+W closes locally; Cmd+Tab and Cmd+Option+Escape remain
local escape routes. Cmd+Shift+I must toggle capture both off and on.

New hosts report Accessibility permission in their heartbeat. A viewer shows
a warning when the host cannot inject input; grant permission on the host Mac.

Drops require updated peers, a password-protected session, and clipboard sync
enabled on both Macs. Regular files are fetched immediately through the encrypted
clipboard channel into the host's clipboard cache, then placed on its clipboard.
Text/images also populate the remote clipboard. Paste into the desired remote
application after transfer. This is not native drag-and-drop into the remote
application, and folders/file promises are not supported. The viewer's "offered"
message is not a delivery acknowledgement. Existing clipboard size/count limits
apply; disabling sync or copying newer content can cancel an in-flight offer.

Before releasing these changes, test two Macs: select the viewer from another
app, close via traffic light and Cmd+W, minimize/restore/full-screen, toggle capture
twice, type, copy/paste both directions, and drop text and multiple documents.
Verify a host without Accessibility shows the warning, an old host rejects drops
clearly, and newer clipboard content is preserved if it changes during transfer.
