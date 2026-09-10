# LocalCast source map

LocalCast is the engine behind TidalDrift’s **Metal Streaming** feature. For setup, viewer controls, tuning, and validation, read the [LocalCast guide](../../docs/LOCALCAST.md). Clipboard behavior and protocol details live in [Clipboard sync](../../docs/CLIPBOARD_SYNC.md).

## Core and settings

- [LocalCastService.swift](Core/LocalCastService.swift): host/viewer lifecycle, settings application, wake recovery, and Bonjour advertising.
- [LocalCastConfiguration.swift](Core/LocalCastConfiguration.swift) and [StreamingParameters.swift](Core/StreamingParameters.swift): persisted configuration, tuning validation, and resolution precedence.
- [CaptureSettingsRecovery.swift](Core/CaptureSettingsRecovery.swift): bounded recovery after capture/settings failure.

## Capture, input, and media

- [HostSession.swift](Host/HostSession.swift) and its adjacent extensions: client authentication, capture transitions, app enumeration/retargeting, input routing, and recovery.
- [ScreenCaptureManager.swift](Host/ScreenCaptureManager.swift): ScreenCaptureKit capture and live updates.
- [VideoEncoder.swift](Host/VideoEncoder.swift): required hardware H.264/HEVC encoding and access units.
- [InputInjector.swift](Host/InputInjector.swift): remote keyboard/pointer events and app/window actions.
- [VideoDecoder.swift](Client/VideoDecoder.swift): hardware decode, codec detection, and decoder replacement.
- [MetalRenderer.swift](Client/MetalRenderer.swift): IOSurface textures, color conversion, presentation buffers, and GPU resource lifetime.
- [TileCodec.swift](Core/TileCodec.swift): experimental region tiles.

## Viewer, transport, and clipboard

- [ClientSession.swift](Client/ClientSession.swift): connection/authentication, recovery, stream requests, statistics, and clipboard integration.
- [LocalCastViewerWindow.swift](Views/LocalCastViewerWindow.swift) and [RemoteKeyboardTap.swift](Client/RemoteKeyboardTap.swift): viewer window, Stream Controls, input capture, and drops.
- [LocalCastSettingsView.swift](Views/LocalCastSettingsView.swift): Metal Streaming settings UI.
- [PacketProtocol.swift](Transport/PacketProtocol.swift) and [UDPTransport.swift](Transport/UDPTransport.swift): wire packets, bounded fragmentation/reassembly, pacing, and FEC.
- [SessionCrypto.swift](Security/SessionCrypto.swift): pairing versions, session encryption, and clipboard key derivation.
- [Clipboard](Clipboard): pasteboard synchronization, file promises, and authenticated TCP bulk transfer.

Run package tests from `TidalDrift` with `swift test`. For hardware tests and two-Mac release checks, use the [validation procedure](../../docs/LOCALCAST.md#developer-validation).
