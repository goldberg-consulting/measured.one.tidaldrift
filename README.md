<img src="TidalDrift/PressKit/Screenshots/TidalDrift-Icon-256.png" alt="TidalDrift app icon" width="96">

# TidalDrift

**Screen sharing, app streaming, and file transfer from your Mac’s menu bar.**

TidalDrift brings the computers on your local network into one place. Find a nearby Mac, open its desktop, work in a remote app, send a file, or start an SSH session—all from the menu bar.

[Download](https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/latest) · [Getting started](docs/GETTING_STARTED.md) · [Documentation](docs/README.md) · [Report an issue](https://github.com/goldberg-consulting/measured.one.tidaldrift/issues)

## What you can do

- **Work on another Mac.** Use LocalCast for desktop and app/window streaming, with remote mouse and keyboard control. You’ll see it called **Metal Streaming** in the app.
- **Use familiar connections.** Open macOS Screen Sharing for VNC, Finder for shared folders, or Terminal for SSH.
- **Copy here, paste there.** Sync text, rich text, images, and files during LocalCast sessions. File and large-content transfers require a password-authenticated session.
- **Send files with TidalDrop.** Keep TidalDrift in the Dock, drop files onto its icon, choose one or more devices, and send. TidalDrop uses an existing mounted share when available or a direct connection to another TidalDrift app.
- **Find your devices.** Bonjour discovers advertised services; **Discover Devices** also scans the local subnet. Saved credentials live in Keychain, and Wake-on-LAN can help bring a sleeping device back.
- **Connect to a Raspberry Pi.** The Linux companion sets up a VNC desktop and SSH discovery. See the [Raspberry Pi guide](docs/RASPBERRY_PI.md).

Built with Swift, SwiftUI, and Apple frameworks. No third-party Swift package dependencies.

## LocalCast: responsive streaming between Macs

LocalCast is TidalDrift’s native streaming engine, labeled **Metal Streaming** in the app. It connects directly over your local network and puts another Mac’s desktop, app, or window in a native viewer.

- **Share a desktop, app, or window.** Switch what you’re viewing from the host or the viewer’s app picker.
- **Work in the remote session.** Use mouse and keyboard control, forward shortcuts, and switch to view-only mode when needed.
- **Bring your clipboard along.** Copy text, rich text, images, and regular files in either direction. Drop files onto the viewer to make them available on the host’s clipboard.
- **Adjust the picture as you work.** Tune frame rate, bitrate, quality, resolution, and codec during a session. Choose transport settings for Wi-Fi or a fast wired LAN.

**Built for speed.** ScreenCaptureKit captures the host, VideoToolbox uses hardware H.264/HEVC encoding and decoding, and Metal renders the viewer. Direct UDP transport, adaptive bitrate, and optional forward error correction help balance responsiveness, image quality, and uneven network conditions. Actual frame rate and latency depend on the Macs, resolution, content, and network.

**Password-protected, encrypted sessions.** Authentication is enabled by default. Password-authenticated sessions encrypt video and control traffic with AES-256-GCM; files and large clipboard content use a separately keyed encrypted channel. The host password is stored in Keychain. Turning authentication off also turns off session encryption and makes the host accessible to reachable peers without a password.

**Still improving.** LocalCast is under active development and can still be unstable at times. If a stream stalls or needs reconnecting, the [troubleshooting guide](docs/TROUBLESHOOTING.md) can help; reproducible reports help improve recovery and reliability.

[Set up LocalCast](docs/LOCALCAST.md#start-a-session) · [Quality and speed controls](docs/LOCALCAST.md#tune-picture-quality) · [Security details](docs/LOCALCAST.md#connection-and-security-details) · [Clipboard capabilities and limits](docs/CLIPBOARD_SYNC.md)

## Install

Requires **macOS 13 Ventura or later**. For LocalCast, run TidalDrift on both Macs on the same local network. Standard VNC, SMB, and SSH targets only need the corresponding service enabled.

### Download the app

1. Open the [latest release](https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/latest) and download the DMG. Check its release notes for signing and notarization status.
2. Open the DMG and drag **TidalDrift** to **Applications**.
3. Launch TidalDrift and click its menu-bar icon.

### Homebrew

```bash
brew install --cask goldberg-consulting/tap/tidaldrift
```

If Homebrew asks you to grant trust, trust the TidalDrift cask and repeat the install command:

```bash
brew trust --cask goldberg-consulting/tap/tidaldrift
```

See Homebrew’s [tap trust documentation](https://docs.brew.sh/Tap-Trust) for details. To update an installed copy:

```bash
brew upgrade --cask tidaldrift
```

## Your first connection

1. **Open TidalDrift.** Allow local network access when macOS asks. The setup wizard walks through the system sharing services; enable the ones you plan to use.
2. **Prepare the target Mac.** Enable **Screen Sharing** in its system Sharing settings, and allow the account you’ll use to connect. You can also use TidalDrift’s setup wizard on that Mac.
3. **Connect.** Find the target under **Nearby Devices**, hover over its row, and click **Screen Share (VNC)**. Sign in through macOS Screen Sharing.

For TidalDrift’s own streaming viewer, follow [Set up LocalCast](docs/GETTING_STARTED.md#set-up-localcast-metal-streaming). It covers the host password, capture permissions, and **Start Cast** action.

## Documentation

- [Getting started](docs/GETTING_STARTED.md) — first launch, permissions, and everyday connections.
- [LocalCast](docs/LOCALCAST.md) — stream a desktop or app, control input, and tune picture quality.
- [Clipboard sync](docs/CLIPBOARD_SYNC.md) — copy and paste between Macs, including files.
- [File transfer](docs/FILE_TRANSFER.md) — TidalDrop, shared folders, and where received files go.
- [Discovery and networking](docs/BONJOUR_DISCOVERY.md) — find devices and understand network requirements.
- [Raspberry Pi and Linux](docs/RASPBERRY_PI.md) — install and configure the companion package.
- [Troubleshooting](docs/TROUBLESHOOTING.md) — resolve discovery, permissions, and connection problems.

The [documentation index](docs/README.md) also links to developer references and historical notes.

## Build and contribute

The macOS app is a Swift package in [`TidalDrift/`](TidalDrift). With Xcode and Swift 5.9 or later available:

```bash
cd TidalDrift
swift build
swift test
```

These commands compile and test the package. To create a runnable app bundle, follow [Contributing](CONTRIBUTING.md), which covers the development script’s installation and permission-reset behavior. Maintainers can use the [release guide](RELEASE.md) for packaging and distribution.

## License

[MIT](LICENSE). Developed by [Goldberg Consulting, LLC d/b/a Measured.One](https://measured.one).
