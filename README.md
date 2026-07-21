# TidalDrift

A menu-bar Mac utility for discovering, connecting to, and streaming between Macs on your local network. Built entirely with Apple frameworks; no external dependencies.

TidalDrift replaces the manual workflow of opening System Settings, toggling sharing services, remembering IP addresses, and launching Screen Sharing.app. It lives in your menu bar, discovers every Mac on your LAN via Bonjour, and provides one-click access to screen sharing (VNC), file sharing (SMB), SSH, and its own low-latency streaming engine, LocalCast.

> **Development status:** The custom LocalCast pipeline (ScreenCaptureKit capture, VideoToolbox HEVC/H.264 encoding, NV12 end to end, Metal rendering, UDP transport with FEC and adaptive bitrate) is functional: capture, encode, transport, decode, and render run end to end, and a two-stage viewer watchdog recovers from a host settings restart instead of freezing. Remaining limitations are honest ones: the client-driven in-viewer app picker is currently dormant (host-initiated sharing via the menu-bar picker is the active path), the password key derivation is not yet a brute-force-resistant hash, and on a lossy uplink UDP's lack of retransmit can still break frames. Full-desktop VNC streaming, network discovery, file transfer, clipboard sync, and all other features are functional. See [TidalDrift/LocalCast/README.md](TidalDrift/LocalCast/README.md) for details.

## Features

**Menu-Bar Command Center**
- Lives entirely in the menu bar; no main window needed
- Compact popover shows your Mac's sharing status, all discovered devices, and inline action buttons
- One-click LocalCast, VNC, SMB, and SSH connections from any device row
- Drag files onto the Dock icon to send to multiple devices at once

**LocalCast: Low-Latency Screen Streaming**
- Custom streaming engine: ScreenCaptureKit capture, VideoToolbox HEVC/H.264 encoding, NV12 end to end, Metal rendering, raw UDP transport
- Sub-frame latency on gigabit LAN
- Stream full display or a single app/window
- Auto/Resilient/Fast LAN transport profiles, adaptive bitrate, forward error correction, and an adaptive jitter buffer
- AES-256-GCM session encryption with per-packet authentication once keyed (pairing key via HKDF-SHA256; password never sent over the wire)
- Retina-quality with adaptive resolution (720p to 4K)
- Remote mouse and keyboard input with configurable rate limiting
- Live quality tuning slider synced between client and host

**Network Discovery**
- Bonjour/mDNS service browsing for `_rfb._tcp`, `_smb._tcp`, `_ssh._tcp`, and TidalDrift peers
- Subnet scanning for devices that do not advertise services
- Rich peer metadata broadcast (model, CPU, memory, macOS version, uptime)
- Connection history and saved credentials in Keychain

**TidalDrop: Peer-to-Peer File Transfer**
- Drop files onto any device card or use the Dock icon
- Transfers via mounted SMB share when available; falls back to direct TCP
- Configurable destination folder

**Raspberry Pi / Linux Targets**
- `tidaldrift-pi` Debian companion package (attached to each release) makes a Pi a first-class target: SSH and Screen Share buttons work like a Mac's
- TigerVNC virtual desktop on port 5900 (headless-friendly), advertised over Bonjour, with a stable peer identity so saved logins survive DHCP changes
- VNC compatibility handled automatically: the client probes RFB security types and adapts to classic VncAuth servers (TigerVNC, wayvnc, x11vnc) vs Mac and RealVNC authentication
- Details in [docs/RASPBERRY_PI.md](docs/RASPBERRY_PI.md)

**Other**
- Wake-on-LAN with MAC auto-discovery
- Clipboard sync between Macs
- Guided setup wizard for Screen Sharing, File Sharing, SSH, and Firewall
- Built-in integration test suite (22 tests covering Bonjour, networking, crypto, file transfer, and streaming)

## Installation

### Homebrew (recommended)

Homebrew 6 and later requires trusting a third-party tap before installing
from it (one-time):

```bash
brew trust --tap goldberg-consulting/tap
brew install --cask goldberg-consulting/tap/tidaldrift
```

To update:

```bash
brew upgrade --cask tidaldrift
```

### Manual

Download the latest signed and notarized DMG from [Releases](https://github.com/goldberg-consulting/measured.one.tidaldrift/releases), open it, and drag TidalDrift to Applications.

## Requirements

- macOS 13.0 (Ventura) or later
- Xcode 15+ with Swift 5.9+ for building from source

## Building

TidalDrift uses Swift Package Manager. The project builds with either `xcodebuild` or `swift build`.

### Development Build (recommended)

The dev build script handles signing, DMG creation, installation to `/Applications`, and TCC permission resets:

```bash
cd TidalDrift
chmod +x build-app.sh
./build-app.sh
```

This requires:
- Xcode selected: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
- A Developer ID certificate in your Keychain (falls back to ad-hoc signing if unavailable)

### Release Build (signed + notarized)

```bash
cd TidalDrift
chmod +x build-release.sh
./build-release.sh
```

The release build adds hardened runtime, notarization via Apple's notary service, and ticket stapling. It requires a `.env` file; see [Configuration](#configuration) below.

To skip notarization (sign only):

```bash
./build-release.sh --skip-notarize
```

To copy the release DMG to the maintainer SMB share, enable the optional flag:

```bash
COPY_TO_SHARE=1 ./build-release.sh
```

By default, network share copy is disabled so OSS builds remain portable.

### Swift Package Manager

```bash
cd TidalDrift
swift build
```

Note: `swift build` compiles the code but does not create an `.app` bundle with the required `Info.plist`, entitlements, or code signing. Use `build-app.sh` for a runnable app.

### Continuous Integration

GitHub Actions validates three paths on every push and pull request to `main`:

- `swiftlint` for style and lint checks
- `swift build` and `swift test` for SwiftPM compile and test coverage
- `xcodebuild` on the `TidalDrift` scheme (with code signing disabled) to validate the app target build path

### Releasing

Releases are automated via GitHub Actions. When a GitHub Release is published, the workflow:

1. Builds the app with `xcodebuild` (Release configuration)
2. Creates the `.app` bundle with correct `Info.plist` and entitlements
3. Signs with a Developer ID certificate imported from encrypted secrets
4. Creates and signs the DMG
5. Notarizes via Apple's notary service and staples the ticket
6. Uploads the notarized DMG to the GitHub Release
7. Updates the [Homebrew cask](https://github.com/goldberg-consulting/homebrew-tap) with the new version and SHA256

The release workflow runs in a protected GitHub environment (`release`) that requires approval from a maintainer. Only repository admins can publish releases.

No signing certificates, Apple credentials, or secrets are stored in the repository. All sensitive values are configured as GitHub Actions encrypted secrets.

## Permissions

TidalDrift requests several macOS permissions on first use:

| Permission | Purpose |
|---|---|
| **Screen Recording** | Required for LocalCast host to capture the screen |
| **Accessibility** | Required for remote input injection (mouse/keyboard) on the host |
| **Local Network** | Required for Bonjour discovery and direct connections |

The build scripts automatically reset TCC permissions on each rebuild, since code signature changes invalidate previous grants.

## Architecture

```
TidalDrift/
  App/                    # App entry point, delegate, state management
  Views/
    MenuBarView.swift     # Primary UI: menu bar popover
    DropTargetPicker.swift # Multi-device file send picker
    Settings/             # Settings window tabs (incl. test suite)
    Dashboard/            # Device grid/list views
    DeviceDetail/         # Standalone device detail windows
    Onboarding/           # First-run setup wizard
  LocalCast/
    Core/                 # Configuration, service, permissions
    Host/                 # Screen capture, video encoding, input injection
    Client/               # Session management, video decoding
    Transport/            # UDP transport, packet protocol
    Security/             # AES-256-GCM crypto, HKDF key derivation
    Views/                # Viewer window, quality controls, app picker
  Services/               # Bonjour, TidalDrop, clipboard sync, discovery
    TestSuite/            # In-app integration tests
  Models/                 # DiscoveredDevice, ConnectionRecord, AppSettings
  ViewModels/             # Dashboard/device detail view models
  Utilities/              # NetworkUtils, ShellExecutor
linux/
  tidaldrift-pi/          # Debian companion package for Pi/Linux targets
```

## Configuration

### Build version metadata (`TidalDrift/version.env`)

Both build scripts load app version values from `TidalDrift/version.env`:

```bash
APP_VERSION=1.4.3
BUILD_NUMBER=10403
```

`APP_VERSION` maps to `CFBundleShortVersionString` and `BUILD_NUMBER` maps to `CFBundleVersion` in generated app bundles.

### Notarization credentials (`TidalDrift/.env`)

The release build script sources `TidalDrift/.env` for Apple notarization credentials. This file is gitignored and must never be committed.

```bash
cp TidalDrift/.env.template TidalDrift/.env
```

Then edit `TidalDrift/.env` with your values:

| Variable | Description | Where to get it |
|---|---|---|
| `APPLE_ID` | Your Apple Developer account email | [developer.apple.com](https://developer.apple.com) |
| `TEAM_ID` | Your 10-character Apple Developer Team ID | Xcode > Settings > Accounts > Team ID, or [Membership](https://developer.apple.com/account#MembershipDetailsCard) |
| `APP_SPECIFIC_PASSWORD` | An app-specific password for notarytool | [appleid.apple.com](https://appleid.apple.com) > Sign-In and Security > App-Specific Passwords |
| `NOTARY_PROFILE` | Keychain profile name (default: `notarytool-profile`) | Auto-created by the build script on first run |

On the first notarization run, the script stores these credentials in your login keychain under the profile name, so subsequent runs do not need the plaintext values. You can also store them manually:

```bash
xcrun notarytool store-credentials "notarytool-profile" \
  --apple-id "you@example.com" \
  --team-id "XXXXXXXXXX" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

### Developer ID certificate

Both build scripts require a **Developer ID Application** certificate in your Keychain. The dev build (`build-app.sh`) falls back to ad-hoc signing if none is found; the release build (`build-release.sh`) exits with an error.

Verify your certificate is installed:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

## Running Tests

Tests run inside the app itself. Launch TidalDrift, open **Settings > Tests**, and click **Run All Tests**. The suite covers:

- **Permissions**: Screen Recording, Accessibility, network availability
- **Bonjour**: Service advertising, self-discovery, LocalCast UDP browse
- **Network**: TCP/UDP port binding, loopback echo roundtrips
- **Security**: Key generation, HKDF derivation, AES-GCM encrypt/decrypt, tamper detection
- **TidalDrop**: Loopback file transfer (small and large), destination folder validation
- **LocalCast**: Streaming tuning interpolation, packet protocol serialization, host session lifecycle

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development workflow and guidelines.

## License

MIT License. See [LICENSE](LICENSE) for details.

## Credits

Developed by [Goldberg Consulting, LLC d/b/a Measured.One](https://measured.one).
