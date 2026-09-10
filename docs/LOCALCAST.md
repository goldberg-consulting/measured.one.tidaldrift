# LocalCast: stream and control another Mac

LocalCast is TidalDrift’s streaming engine, called **Metal Streaming** in the app. It opens another Mac’s desktop, app, or window in a native viewer, with remote keyboard and mouse control and bidirectional clipboard sync.

It is built for responsive local-network use: hardware H.264/HEVC encoding and decoding, Metal rendering, and direct UDP transport. Password-authenticated sessions encrypt video, control, and clipboard traffic. Resolution, content, hardware, and the network determine the speed you experience.

LocalCast is under active development and can still be unstable at times. Recovery and reliability remain active work; see [Troubleshooting](TROUBLESHOOTING.md) if a session stalls or needs reconnecting.

This guide covers everyday use first, then settings and implementation details. For installation and first launch, start with [Getting started](GETTING_STARTED.md).

## Start a session

On the **host Mac** — the Mac you want to view:

1. Open **Settings → Metal Streaming**.
2. Leave **Require authentication** enabled and set a **Host password**. This is the TidalDrift hosting password; it does not have to match the Mac’s login password.
3. Grant **Screen Recording** for capture and **Accessibility (for input)** for remote control. Allow Local Network access when macOS requests it.
4. Turn on **Host this Mac**. The menu-bar **Metal Streaming Host** toggle controls the same service.

Before connecting from the **viewer Mac**, prepare its saved password. **Authenticated connections currently require a matching saved device password.** Start Cast uses saved device credentials; it does not open a password-entry sheet. The dashboard password sheet present in the source is not exposed by the current menu-bar app.

To populate saved credentials through the current interface, open the device’s **Details**, enter a username and the required password under **Saved Credentials**, leave **Save credentials in Keychain** enabled, and launch **Screen Share** or **File Share** from that details window. The app saves after the service launch returns successfully. Entering the fields and clicking **Done** alone does not save them. This uses one shared credential record for the device, so a LocalCast password that differs from its other service password needs care when switching services.

Then connect from the viewer:

1. Open the TidalDrift menu and find the host under **Nearby Devices**.
2. Hover over its row and click the lightning-bolt **Start Cast** action.
3. Click in the viewer to control the host. If the viewer reports **View only: enable TidalDrift in Accessibility settings on the host Mac**, grant that permission on the host.

Both Macs need a reachable network path and compatible TidalDrift builds. A host serves one active viewer at a time. To end sharing, turn off **Host this Mac** or **Metal Streaming Host**. **Auto-host on launch** starts hosting whenever TidalDrift launches.

## Choose what to share

On the host, open the menu-bar **Sharing:** menu and choose **Entire Desktop** or an app. Use **Refresh App List** after opening an app if it is missing.

Inside the viewer, click the top-edge chevron to open **Stream Controls**, then choose **Apps**. You can switch to **Full Display**, stream an app, expand its row to choose a window, or bring the app to the foreground. The current target also appears in the bottom status bar; clicking it opens the Apps tab.

The app list includes apps with visible, titled windows of a usable size. Hidden, minimized, untitled, background, and some system windows can be absent. Make the desired window visible on the host and refresh the list.

The host and viewer can both change the capture target. Selecting an app is a capture choice, not a restriction that prevents the connected viewer from requesting the full display. Invalid or closed app/window requests fail without automatically switching to the entire desktop.

## Keyboard, mouse, and viewer controls

The bottom status bar switches between **Remote Control** and **View Only**. Press **⌘⇧I** to toggle remote control without using the mouse.

While control is enabled and the viewer is focused, typing and pointer actions go to the host. Host Accessibility permission enables input injection. Viewer Accessibility permission enables capture of system shortcuts; without it, ordinary keys use a fallback handler.

- **⌘⇧I:** release or resume remote control.
- **⌘W while controlling:** close the remote app’s window.
- **⌘W after releasing control:** close the local viewer when Stream Controls is closed. The title-bar Close button also closes the viewer.
- **⌘Tab** and **⌘⌥Escape:** remain local so you can switch apps or open Force Quit.

The viewer supports normal macOS minimize and full-screen controls. Opening Stream Controls makes its controls local rather than forwarding clicks or keystrokes to the host.

The stream omits the host’s cursor by default so the viewer uses its local pointer. Enable **Show remote cursor in stream** on the host when you want to watch the host user’s pointer, such as during a view-only session.

## Copy, paste, and drop files

Enable **Clipboard Sync** on both Macs. You can also find it at **Settings → General → Sync clipboard during LocalCast sessions**.

Copy text, rich text, HTML, an image, or regular files on either Mac, then paste on the other. Files transfer when the receiving app requests them on paste. Password-protected sessions support files and large content; passwordless sessions support only small inline clipboard content.

You can also drop regular files, text, or images onto the viewer. This sends content to the **host’s clipboard**; paste it into the remote app after transfer. Files dropped onto the viewer transfer immediately. This workflow requires a password, Clipboard Sync on both Macs, and builds that support viewer drops. The “Drop offered” message confirms the offer, not completed delivery.

The limit is **100 MiB total and 64 regular files**. Folders and app bundles are unsupported. [Clipboard sync](CLIPBOARD_SYNC.md) explains privacy, supported formats, file promises, and retry behavior. TidalDrop is a separate file-transfer feature; it does not use this clipboard channel.

## Tune picture quality

Start with the **Streaming Quality** slider in **Settings → Metal Streaming** or **Stream Controls → Quality**. Move toward **Fastest** to reduce the workload, or **Best Quality** for more detail. Expand **Fine-Tune Controls** to adjust frame rate, bitrate, encoder quality, and resolution individually.

Requested settings can be reduced by congestion, thermal pressure, or transport capacity. The initial quality preset is used when saved live tuning is absent; it does not overwrite existing saved tuning.

### Changes that apply during a session

Bitrate, frame rate, and encoder quality update live. **Video Codec**, **Streaming resolution**, and **Region-aware streaming** rebuild capture and encoding within the existing session. Changes coalesce briefly, so the picture may hold while the new stream starts; closing Settings does not cancel the change. Authentication and the clipboard channel remain in place during this rebuild.

**Adaptive bitrate**, **Forward error correction (FEC)**, **Transport profile**, **Show remote cursor in stream**, and **Thermal throttling** also apply while hosting.

- **Automatic resolution** follows quality tuning. **Native** adds no configured resolution cap. Named resolutions cap the longest edge while preserving aspect ratio. An explicit viewer resolution override takes precedence over the host’s resolution setting.
- **HEVC (Efficiency)** is the default codec. The encoder can fall back to hardware H.264 if HEVC cannot initialize. **H.264 (Compatibility)** is available directly in Settings.
- **Auto transport** begins conservatively and uses connection measurements to select Fast LAN behavior on a clean wired link. **Resilient (Wi-Fi)** retains pacing for uneven links. Fast LAN does not require or assume jumbo frames.
- **FEC** adds parity traffic to recover some missing video fragments. It can help on a lossy link at the cost of extra bandwidth.
- **Region-aware streaming (experimental)** sends changed areas as lossless tiles and uses full-frame video for large changes. Both peers need support. Keep this distinction in mind when comparing its performance with the default video path.

### Changes that need reconnection or a host restart

**Latency mode**, **Drop to newest frame**, and **Loss-triggered recovery** apply to the next viewer connection.

Changes to **Require authentication**, **Host password**, and **Input rate limit** in Settings apply after stopping and starting hosting. The menu-bar **Require password** switch restarts hosting automatically; editing its password field still needs a host restart.

## Screen Share + App Control

Device details include **Screen Share + App Control** under **Available Services**. This opens macOS Screen Sharing for the picture and a separate TidalDrift panel for app focus and isolation.

The host needs **both** macOS Screen Sharing and LocalCast hosting enabled. LocalCast supplies the app list and control channel, so enabling macOS Screen Sharing alone is insufficient. Authenticated app control uses the saved LocalCast host password. **Isolate** hides other host apps; it does not create a separate remote desktop or an access boundary around one app.

For LocalCast’s own app/window capture, open **Start Cast**, then **Stream Controls → Apps**.

## Connection and security details

LocalCast advertises `_tidaldrift-cast._udp` and listens on **UDP 5904**. Bulk clipboard transfer uses **TCP 5906**, with connections initiated by the viewer. [Bonjour discovery](BONJOUR_DISCOVERY.md) describes discovery and address resolution; [Troubleshooting](TROUBLESHOOTING.md) covers connection failures and permissions.

Authentication is enabled by default and hosting refuses to start without a password when it is required. The host password is stored in the macOS Keychain. Password-protected sessions encrypt video and control traffic with AES-256-GCM. Turning authentication off allows reachable peers to view and control the host without a password and sends session traffic without that encryption.

Bonjour advertisements identify connection candidates, not cryptographically verified hosts. Pairing currently supports a password-stretched v2 handshake and legacy v1 compatibility. Clipboard bulk transfers derive their own key from the authenticated session; see [clipboard protocol and security](CLIPBOARD_SYNC.md#protocol-and-security) for its exact guarantees and remaining protocol limits.

## How the stream works

The default full-frame pipeline is:

1. **ScreenCaptureKit** supplies IOSurface-backed NV12 frames on the host.
2. **VideoToolbox** hardware encodes H.264 or HEVC.
3. **UDP transport** encrypts keyed-session packets, fragments frames, and applies pacing and optional FEC.
4. **VideoToolbox** hardware decodes complete access units on the viewer.
5. **Metal** converts YUV to display color and presents retained IOSurface textures.

Encode/decode use hardware media engines; Metal handles presentation. Packet handling, encryption, input, and clipboard work still use the CPU. Experimental region tiles add CPU copies and LZFSE compression.

The full-frame video path is **8-bit 4:2:0 SDR**. Audio, HDR, and 4:4:4 video are not implemented. Hardware codecs and Metal rendering are required; there is no software codec fallback. Initialization failures surface as connection/capture errors.

Capture transitions are serialized, including settings changes, target changes, and recovery. A failed listener or system wake triggers a host restart and client reauthentication. Recovery is bounded; a prolonged outage can require reconnecting.

Video loss can trigger a keyframe request. FEC can reconstruct up to two missing full-size data fragments per block, but not the short final fragment without its length. The protocol does not selectively retransmit video or acknowledge every control operation.

**Info** shows connection statistics. Its latency value is heartbeat **network round-trip time**, not capture-to-display or input-to-photon latency. FPS counts received media activity, not guaranteed displayed frames. Those statistics alone do not establish performance relative to macOS Screen Sharing.

## Developer validation

The [module source map](../TidalDrift/LocalCast/README.md) identifies implementation files. The Swift package has deterministic tests for transport, settings, capture recovery, media parsing, color conversion, and clipboard behavior. From the repository root:

```sh
cd TidalDrift
swift test
```

Hardware validation runs on a Mac with the required codecs and Metal support:

```sh
LOCALCAST_REQUIRE_HARDWARE_TESTS=1 swift test -c release
```

This enables real H.264/HEVC round trips, codec/resolution recovery, and a synthetic IOSurface NV12 4K benchmark. The benchmark excludes capture, network, and presentation latency and uses a static image with at most three outstanding pictures. Add `LOCALCAST_MIN_4K_FPS=60` only when intentionally enforcing a 60-fps capacity threshold on controlled hardware.

Before shipping streaming changes, test on **two Macs running the same revision**. Record chips, macOS versions, display resolution/scaling/refresh, codec and tuning overrides, network interfaces/MTU, and power/thermal state.

1. **Connect and control:** authenticate; switch focus, minimize, and enter full screen; type and scroll; toggle ⌘⇧I twice; verify remote ⌘W and local Close behavior; revoke host Accessibility and verify the warning.
2. **Change targets and settings:** switch desktop/app/window, close the shared window, and edit codec, resolution, region mode, and quality while streaming. Close Settings immediately after an edit. Confirm the target, input mapping, authentication, and clipboard remain correct.
3. **Exercise recovery:** test Wi-Fi and standard-MTU Ethernet, packet loss/bursts, interface changes, sleep/wake, and listener failure. Record recovery time and failures, including any needed reconnect.
4. **Check clipboard:** use the [clipboard verification cases](CLIPBOARD_SYNC.md#developer-verification), including newer copies during transfers and sync disabled mid-transfer.
5. **Measure performance:** test small text, gradients, photos, and motion over a sustained session. Measure actual displayed frame intervals, input-to-photon latency, wire bitrate, memory, and thermal load. For comparisons with macOS Screen Sharing, match resolution/frame rate, warm up, repeat runs, and report raw results plus median, p95, worst case, and failures.

Unit tests and the synthetic benchmark complement these checks; they do not replace two-Mac validation or certify a particular resolution/frame-rate target.

[Documentation index](README.md)
