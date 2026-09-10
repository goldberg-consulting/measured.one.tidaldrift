# Mac App Store planning

This is an unimplemented planning checklist for a possible Mac App Store edition. The repository's current distribution pipeline builds a Developer ID app and DMG for GitHub releases and Homebrew. It does not archive or submit an App Store build. See the [release guide](../../RELEASE.md) for the supported maintainer workflow.

## Current implementation

[TidalDrift.entitlements](../TidalDrift.entitlements) does not enable `com.apple.security.app-sandbox`. It declares Apple Events automation, network client/server, and selected-file/downloads access. Adding those entitlements does not enable App Sandbox.

Several current features need design work before an App Store edition can be assessed:

- [SharingConfigurationService](../Services/SharingConfigurationService.swift) runs administrator-authorized AppleScript and system service commands.
- [NetworkDiscoveryService](../Services/NetworkDiscoveryService.swift) uses the system `dns-sd` executable alongside framework-based discovery.
- [VirtualDisplayController](../LocalCast/Host/VirtualDisplayController.swift) uses private CoreGraphics virtual-display classes.
- LocalCast remote input, capture, clipboard file access, and launching external connection apps need review in a sandboxed build.

Apple requires App Sandbox for Mac App Store distribution and public APIs for submitted apps. The current virtual-display implementation and unsandboxed build therefore need changes before submission. See Apple's [App Sandbox guidance](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) and [App Review Guidelines, sections 2.4.5 and 2.5.1](https://developer.apple.com/app-store/review/guidelines/).

## Engineering work

- [ ] Decide which features an App Store edition would support and document differences from the direct-download app.
- [ ] Create a sandboxed build configuration and verify discovery, network connections, file access, automation, and permission prompts in that configuration.
- [ ] Replace or omit private virtual-display API use in the submitted build.
- [ ] Redesign administrator-dependent setup actions and validate how external connection apps are launched.
- [ ] Verify capture, remote input, clipboard transfer, and saved credentials under the proposed entitlements.
- [ ] Establish an App Store signing, provisioning, archive, and upload workflow separate from the Developer ID DMG builder.
- [ ] Inspect the final built bundle's metadata, entitlements, icon, minimum OS version, and CPU architectures.

## Product and submission work

- [ ] Recheck Apple's current review requirements before committing to a submission.
- [ ] Set up the App Store Connect record, distribution terms, and pricing for the proposed edition.
- [ ] Publish support and privacy-policy pages, then document actual data handling and complete the relevant privacy declarations.
- [ ] Review the [press kit](README.md) copy against the features included in the submitted build.
- [ ] Capture current product screenshots, remove personal data, and follow Apple's [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/). The checked-in press-kit images are icon exports only.
- [ ] Prepare reviewer instructions that explain the second-machine setup, required permissions, and how to exercise each included network feature.
- [ ] Test a clean install and upgrade on each supported macOS version and architecture, including denied permissions, unavailable peers, interrupted sessions, and firewall restrictions.

These unchecked items describe work to establish readiness. They do not imply an approved exception, a completed compliance review, or a committed release date.

---

[Project overview](../../README.md) · [Documentation index](../../docs/README.md)
