# TidalDrift documentation

Start with [Getting started](GETTING_STARTED.md) to connect two Macs. Looking for the app itself? [Download TidalDrift](https://github.com/goldberg-consulting/measured.one.tidaldrift/releases/latest).

## Use TidalDrift

- [Getting started](GETTING_STARTED.md): install, configure permissions, and make your first connection.
- [LocalCast / Metal Streaming](LOCALCAST.md): share a desktop or app and adjust the viewing experience.
- [Clipboard sync](CLIPBOARD_SYNC.md): copy text, images, and files across a LocalCast session.
- [File transfer](FILE_TRANSFER.md): send files with TidalDrop or open a shared folder.
- [Discovery and networking](BONJOUR_DISCOVERY.md): how devices appear and what your network needs.
- [Raspberry Pi and Linux](RASPBERRY_PI.md): set up a Linux target for VNC and SSH.
- [Troubleshooting](TROUBLESHOOTING.md): start with the symptom you’re seeing.

## Develop and maintain

- [Contributing](../CONTRIBUTING.md): local builds, tests, repository layout, and pull requests.
- [Release guide](../RELEASE.md): versioning, signing, packaging, and release automation.
- [LocalCast source map](../TidalDrift/LocalCast/README.md): find the capture, transport, rendering, and clipboard code.
- [Press kit](../TidalDrift/PressKit/README.md): available icons and product copy.
- [App Store planning](../TidalDrift/PressKit/APP_STORE_CHECKLIST.md): work to assess before a possible App Store distribution.

## Names used in these guides

**TidalDrift** is the app. **LocalCast** is its streaming engine, labeled **Metal Streaming** in the interface. The **host** shares a Mac’s display or app; the **viewer** is the Mac connecting to it. **Screen Share (VNC)** opens macOS Screen Sharing. **TidalDrop** sends files independently of a LocalCast session.

## Historical notes

[App-sharing investigation](APP_SHARING_INVESTIGATION.md) records earlier implementation work. Use the current LocalCast guide for supported workflows.

[Back to the repository README](../README.md)
