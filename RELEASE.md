# Releasing TidalDrift

This is the maintainer guide for packaging and publishing the macOS app and Linux companion. For published versions and their changes, see [GitHub Releases](https://github.com/goldberg-consulting/measured.one.tidaldrift/releases). For local development, see [Contributing](CONTRIBUTING.md).

## Version metadata

[TidalDrift/version.env](TidalDrift/version.env) defines `APP_VERSION` and `BUILD_NUMBER`. The primary development builder, release builder, and GitHub release workflow read this file when generating app metadata.

Before a release:

1. Update `APP_VERSION` and increment `BUILD_NUMBER` in `version.env`.
2. Keep `CFBundleShortVersionString` and `CFBundleVersion` in [TidalDrift/Info.plist](TidalDrift/Info.plist) consistent. The primary builders generate their own plist, but the checked-in plist remains an input to the older builder.
3. Complete the applicable [contribution checks](CONTRIBUTING.md#validate-a-change) and review the changes being released.
4. Use a release tag of `v<APP_VERSION>` pointing to the commit with that metadata. The workflow reads the version from the file, not the tag, and does not check that they match.

Edit `version.env` directly. The older [bump-version.sh](TidalDrift/bump-version.sh) rewrites values in the build scripts instead of updating this source of truth.

The Linux companion has its own version in [linux/tidaldrift-pi/pkg/DEBIAN/control](linux/tidaldrift-pi/pkg/DEBIAN/control). It does not automatically inherit the macOS version.

## Local release build

Use [TidalDrift/build-release.sh](TidalDrift/build-release.sh) from the `TidalDrift/` directory. It requires full Xcode and a Developer ID Application certificate with its private key in the Keychain.

For notarization, configure a Keychain profile interactively:

```bash
xcrun notarytool store-credentials "notarytool-profile"
```

Alternatively, copy `TidalDrift/.env.template` to `TidalDrift/.env` and fill in `APPLE_ID`, `TEAM_ID`, and `APP_SPECIFIC_PASSWORD`. The release builder reads the local file and can use these values to create the profile. `NOTARY_PROFILE` overrides the profile name. Keep credentials out of commits and command history.

From the repository root:

```bash
cd TidalDrift
./build-release.sh
```

The builder stops TidalDrift, attempts to reset its Screen Recording, Accessibility, Input Monitoring, and Local Network grants, and removes the previous temporary app and Xcode build directory. It then:

1. Builds the Release configuration and assembles the app bundle.
2. Signs the app with hardened runtime and verifies its signature.
3. Creates and signs `dist/TidalDrift-<APP_VERSION>.dmg`.
4. Submits the DMG for notarization, waits for completion, and staples the ticket.

The build log is `dist/logs/build-release.log`. The temporary app and build directory are removed after success; the script does not install or launch the release app. Network-share copying is disabled by default. Leave `COPY_TO_SHARE` unset for ordinary builds.

For a signed build without notarization, use `./build-release.sh --skip-notarize`. A Developer ID certificate is still required. Without this flag, missing notarization credentials stop the local build before it can report a completed release.

[TidalDrift/Scripts/build-release.sh](TidalDrift/Scripts/build-release.sh) is an older, separate SwiftPM builder that reads `Info.plist` and has different cleanup and credential behavior. Use the top-level builder above for the workflow described here. `build-app.sh` produces a Debug development build and is not a release packaging step.

## Publish with GitHub Actions

Publishing a GitHub Release triggers [.github/workflows/release.yml](.github/workflows/release.yml). Creating a tag or saving a draft release alone does not trigger it.

Configure the following secrets for the release job:

- `DEVELOPER_ID_P12_BASE64` and `DEVELOPER_ID_P12_PASSWORD` for the signing certificate and private key.
- `APPLE_ID`, `TEAM_ID`, and `APP_SPECIFIC_PASSWORD` for notarization.
- `HOMEBREW_TAP_TOKEN` if the workflow should update `goldberg-consulting/homebrew-tap`.

The job uses the GitHub environment named `release`. Any required reviewers or other protection rules must be configured in the repository settings; the workflow file does not establish those protections.

The job imports the certificate into a temporary Keychain, builds and signs the app and DMG, uploads the DMG to the published release, and computes its SHA-256 checksum. It then updates the external Homebrew tap when the tap token is present and builds and uploads the Linux companion package. The temporary Keychain is deleted in a final cleanup step.

**Notarization is conditional in CI.** If credentials are missing or cannot be stored, the workflow publishes a signed-only DMG and records a warning. If credential setup succeeds, notarization and stapling must succeed before upload. Check the workflow result and state the actual notarization status in the release notes.

The Linux package step runs after the Mac asset and tap update. If it fails, the workflow can show a failure even though the Mac release has already been published. Inspect individual steps before retrying. Asset uploads use `--clobber`, so a rerun can replace an existing asset and change its checksum.

## Verify the published artifacts

- Check that the release tag, app version, build number, and DMG filename agree.
- Download the uploaded DMG and compare its checksum with the workflow output. Confirm the supported CPU architectures from the built executable; the scripts do not explicitly request a universal binary.
- For a notarized release, validate the stapled ticket with `xcrun stapler validate <path-to-dmg>` and assess the mounted app with `spctl --assess --type execute --verbose <path-to-app>`.
- Test installation and upgrade on a Mac outside the build environment. Check discovery, a remote connection, TidalDrop, LocalCast capture/control, and clipboard behavior on a second machine as applicable to the changes.
- Confirm the Homebrew tap points to the uploaded DMG and checksum. If `HOMEBREW_TAP_TOKEN` was absent, the automated tap update was skipped.
- If the companion changed, install its uploaded `.deb` on a supported Linux system and verify setup and discovery.

The workflow copies [Casks/tidaldrift.rb](Casks/tidaldrift.rb) to the external tap and updates the copied version/checksum. It does not update the cask in this repository. After publication, update this repository's cask through a pull request using the uploaded asset's checksum; CI requires that asset to exist.

The cask currently removes the app's quarantine attribute during installation. A successful Homebrew launch therefore does not establish that notarization succeeded; verify the artifact separately.

Mac App Store work is tracked separately in the [App Store planning checklist](TidalDrift/PressKit/APP_STORE_CHECKLIST.md). The release pipeline described here distributes Developer ID builds through GitHub.

---

[Project overview](README.md) · [Documentation index](docs/README.md)
