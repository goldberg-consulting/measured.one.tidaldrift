# Contributing to TidalDrift

Thank you for your interest in contributing to TidalDrift. This document covers the setup, workflow, and conventions for the project.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/TidalDrift.git`
3. Ensure Xcode is selected: `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`
4. Build and run: `cd TidalDrift && ./build-app.sh`

## Development Workflow

- Create a feature branch from `main`: `git checkout -b feature/your-feature`
- Make your changes
- Run local checks: `cd TidalDrift && swift build && swift test`
- Run the in-app test suite: **Settings > Tests > Run All Tests**
- Verify the build completes: `cd TidalDrift && ./build-app.sh`
- Submit a pull request targeting `main`

## CI and Releases

- CI runs `swiftlint`, `swift build`, `swift test`, and `xcodebuild` on every push and PR to `main`.
- Releases are automated: publishing a GitHub Release triggers a workflow that builds, signs, notarizes, uploads the DMG, and bumps the Homebrew cask.
- The release workflow requires maintainer approval via a protected GitHub environment.
- Build version metadata is sourced from `TidalDrift/version.env` (`APP_VERSION`, `BUILD_NUMBER`).
- For local release builds, copy `TidalDrift/.env.template` to `TidalDrift/.env`, then fill in credentials. `build-release.sh` loads `TidalDrift/.env` (never committed). Pass `--skip-notarize` to skip Apple notarization.

## Code Style

- Follow existing Swift conventions in the codebase
- Use `Logger` (os.log) for structured logging; do not use `print` in production paths
- Avoid adding third-party dependencies. TidalDrift is built entirely with Apple frameworks.
- Keep views composable and small; extract reusable components

## Areas for Contribution

- **Bonjour discovery reliability** on complex network topologies (VPN, multiple interfaces)
- **Peer version handshake** and compatibility warnings between TidalDrift instances
- **Accessibility** improvements (VoiceOver, keyboard navigation)
- **Localization** to other languages
- **Linux/cross-platform support** for the networking layer

## Reporting Issues

File issues on GitHub with:
- macOS version
- Steps to reproduce
- Relevant logs (from Console.app, filter by `com.tidaldrift`)

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
