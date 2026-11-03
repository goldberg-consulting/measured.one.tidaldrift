# Contributing to TidalDrift

Start with the [project overview](README.md) and [documentation index](docs/README.md) for the user-facing behavior. This guide covers building, testing, and submitting changes to the macOS app.

## Development setup

You need a Mac and a full Xcode installation. The package declares Swift tools 5.9 and macOS 13 or later; CI builds with Xcode 16.3 on macOS 15. There are no external Swift package dependencies.

Clone your fork or the repository, then create a branch from `main`. Run these commands from the repository root:

```bash
cd TidalDrift
swift build
swift test
```

You can also open `TidalDrift/Package.swift` in Xcode and select the **TidalDrift** scheme. If the command-line tools point to a standalone tools installation, select your installed Xcode in **Xcode > Settings > Locations > Command Line Tools**.

SwiftPM builds the executable and its resources. For a packaged app with its menu bar integration, bundle metadata, and permission identity, use the development helper below.

## Run a development app

From `TidalDrift/`:

```bash
./build-app.sh
```

The helper builds a Debug app, attempts signing, creates `dist/TidalDrift-<version>-dev.dmg`, installs the app in `/Applications`, and launches it. Its build log is `dist/logs/build-app.log`.

**This command replaces `/Applications/TidalDrift.app` and stops any running TidalDrift process.** It also attempts to reset Screen Recording, Accessibility, Input Monitoring, and Local Network permissions for the app; expect to grant permissions again. `./build-app.sh --no-run` skips only the final launch and still performs these other steps.

The current helper's certificate lookup can stop the build if no Developer ID Application identity is available in the Keychain. For a compilation check that does not require signing or install the app, use the same command as CI:

```bash
xcodebuild \
  -scheme TidalDrift \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build
```

## Find the relevant code

- [TidalDrift/App/](TidalDrift/App/) owns app startup, menu bar presentation, and window lifecycle.
- [TidalDrift/Views/](TidalDrift/Views/) contains the dashboard, device actions, setup, and settings UI.
- [TidalDrift/Services/](TidalDrift/Services/) handles discovery, connections, credentials, sharing configuration, and TidalDrop.
- [TidalDrift/LocalCast/](TidalDrift/LocalCast/) contains screen capture, encoding, transport, playback, input, and clipboard sync.
- [TidalDrift/Tests/TidalDriftTests/](TidalDrift/Tests/TidalDriftTests/) contains the SwiftPM tests.
- [TidalDrift/Services/TestSuite/](TidalDrift/Services/TestSuite/) contains the separate in-app integration checks.
- [linux/tidaldrift-pi/](linux/tidaldrift-pi/) packages the Linux companion; see the [Raspberry Pi guide](docs/RASPBERRY_PI.md).

The [technical guides](docs/README.md) explain the connections between these components.

## Validate a change

For Swift changes, run `swift build`, `swift test`, and `swiftlint lint` from `TidalDrift/`. Add focused regression coverage when fixing behavior that the existing tests do not exercise.

For changes involving capture, permissions, discovery, or real connections, run the relevant checks in **Settings > Tests** and test with another computer. The in-app suite includes permission checks and local network exercises; a successful loopback test does not demonstrate that a second machine can discover, authenticate, or control the host. Include the macOS versions and permission state in your results.

Install the repository checks once from the repository root:

```bash
brew install pre-commit swiftlint
pre-commit install
pre-commit run --all-files
```

The hooks check formatting, YAML/JSON, merge markers, large files, private keys, and Swift style. They also prevent local commits to `main` and `master`, so run them on your contribution branch.

[CI](.github/workflows/ci.yml) runs on pull requests to `main` and pushes to `main`. It runs pre-commit, SwiftLint, SwiftPM build/tests, an unsigned Xcode build, and Homebrew cask checks. The cask job downloads the release asset named by the cask and verifies its checksum; that version must already exist when a cask update is tested.

## Submit a pull request

Keep each change focused and follow the surrounding Swift style. Use `Logger` for production diagnostics, keep secrets and clipboard contents out of logs, and avoid adding dependencies when the existing frameworks cover the need. Explain lifecycle and concurrency assumptions where the code depends on them.

Open a pull request against `main` with:

- The problem and what changes for the user.
- The checks you ran and any behavior you could not test.
- Screenshots or a short recording for visible UI changes.
- Documentation updates for changed settings, permissions, protocols, or setup steps.

Keep local credentials, signing certificates, generated app bundles, and DMGs out of commits. The tracked `TidalDrift/version.env` contains release metadata; private signing credentials belong in an ignored local `.env` file or the Keychain.

For bug reports, use [GitHub Issues](https://github.com/goldberg-consulting/measured.one.tidaldrift/issues) and include the app version, macOS version on each machine, network setup, steps to reproduce, and relevant diagnostics. In Console, filter for the `com.tidaldrift` subsystem. Remove credentials, personal file paths, and private device details before sharing logs.

Maintainers should use the [release guide](RELEASE.md) for packaging and publishing. Contributions are covered by the [MIT license](LICENSE).

## Network test helper

Packaged apps include iperf3 3.21 in `Contents/Helpers/iperf3`; users do not need
Homebrew. The release workflow and all three app packaging scripts call `Scripts/bundle-iperf3.sh`, which
verifies the upstream archive SHA-256, builds arm64 and x86_64 slices with a macOS
13 deployment target (checked in each compiled slice), links libiperf statically without OpenSSL, signs the helper,
and includes the upstream license under `Contents/Resources/ThirdParty/`.
The first packaging run needs internet access and a C compiler. SwiftPM Debug
runs need the patched helper to serve a test. The ordinary Homebrew iperf3
executable does not implement the peer restriction.

The updated test requires the updated app on both Macs. TCP port 5905 carries
small control messages from private/link-local peers. After a TCP handshake,
the responder starts a one-off iperf3 server for each phase, on a random port
bound to the same local IPv4 address. A small patch passed to the pinned source at
build time restricts the helper's control socket and every data stream to the
IPv4 address of the peer that opened the app's control connection. Unrelated
connections and UDP setup packets cannot redirect the test. The firewall must allow the app/helper's TCP and UDP
traffic. A disconnect or a 50-second lease ends the helper; individual tests are
limited to ten seconds. Each helper also exits after its one test or twelve
seconds waiting for a client, independently of the app. The control protocol is LAN-only, not user authentication;
do not expose it or the temporary iperf listener through port forwarding.

The UI reports single-stream TCP receive throughput in both directions, then UDP
receiver loss and jitter at a selectable limit of 100, 250, 500, or 1000 Mbps
(default 100), capped at half the corresponding TCP throughput on slower links. This is a streaming delivery check, not a claim that UDP can run
loss-free at the full TCP rate. RTT is measured on the control connection. The
selected source address is also bound for iperf, and the UI identifies that route.
The result distinguishes the requested UDP rate from the rate the sender
actually achieved. Missing or malformed reports are errors, never synthetic packet loss.

To exercise the bundled helper locally without installing or launching the app:

```bash
cd TidalDrift
bash Scripts/bundle-iperf3.sh /tmp/TidalDrift-network-check.app
TIDALDRIFT_TEST_IPERF=/tmp/TidalDrift-network-check.app/Contents/Helpers/iperf3 \
  swift test --filter SpeedTestTests
```

The opt-in integration check runs all four phases over loopback and cancels a
second test. A separate two-Mac Ethernet run is still required to validate actual
LAN performance, firewall prompts, and route selection.
