import Foundation

// The app used to launch via `@main struct TidalDriftApp: App` with a
// SwiftUI `MenuBarExtra(.window)` scene. That scene is broken on recent
// macOS: the status item renders but clicks don't open its popover. The
// entry point now lives on `AppDelegate` (see `@main` there), which owns
// an NSStatusItem + NSPopover directly and hosts `MenuBarView` via
// `NSHostingController`. This file is kept only for the cross-module
// Notification.Name constants that the rest of the app uses.

extension Notification.Name {
    static let scanNetwork = Notification.Name("scanNetwork")
    static let addDeviceManually = Notification.Name("addDeviceManually")
    static let showOnboarding = Notification.Name("showOnboarding")
}
