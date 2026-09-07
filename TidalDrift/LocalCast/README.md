# LocalCast

LocalCast is TidalDrift's custom desktop, app, and window streaming engine.
It runs alongside the separate macOS Screen Sharing connection option.

The host captures IOSurface-backed frames with ScreenCaptureKit, encodes
H.264 or HEVC with VideoToolbox hardware, and sends encrypted video over UDP
when authentication is enabled. The viewer uses hardware VideoToolbox decode
and Metal presentation. Codec hardware and the Metal GPU perform distinct
jobs; networking, encryption, input handling, and experimental tile compression
still execute on the CPU.

Read [the LocalCast guide](../../docs/LOCALCAST.md) for current behavior,
settings contracts, recovery, limitations, and the comparison procedure against
Apple Screen Sharing. Read [clipboard sync](../../docs/CLIPBOARD_SYNC.md) for
supported formats, transfer bounds, privacy exclusions, and file semantics.

## Source map

- `Core/LocalCastService.swift`: hosting/viewer ownership, settings application,
  wake recovery, and Bonjour advertisement.
- `Core/LocalCastConfiguration.swift` and `Core/StreamingParameters.swift`:
  persisted configuration, validated live tuning, and resolution precedence.
- `Host/HostSession.swift`: authenticated client lifecycle, serialized capture
  transitions, congestion control, and capture recovery.
- `Host/ScreenCaptureManager.swift`: ScreenCaptureKit capture and live updates.
- `Host/VideoEncoder.swift`: required hardware codec, low-latency configuration,
  bounded GOP recovery, and Annex B access units.
- `Client/VideoDecoder.swift`: codec detection, complete access-unit decoding,
  hardware enforcement, and decoder replacement.
- `Client/MetalRenderer.swift`: IOSurface textures, color conversion,
  presentation buffer, and GPU resource lifetime.
- `Transport/UDPTransport.swift`: bounded fragmentation/reassembly, pacing,
  forward error correction, and control packets.
- `Clipboard/`: pasteboard synchronization and authenticated TCP bulk transfers.

## Validation

From the package directory run `swift test` and `swiftlint lint`. The automated
suite covers packet parsing, settings bounds, discovery deadlines, clipboard
lifecycle, decoder access units, and rendering arithmetic. Hardware round-trip
tests require a Mac with suitable codecs. Permission-dependent capture and
cross-machine recovery are separate checks in the guide; passing unit tests
does not establish latency or image-quality superiority.
