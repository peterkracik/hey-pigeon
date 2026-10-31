// In-app updates: Sparkle over the appcast that publish-macos writes next
// to every build of main (the mac-latest release on GitHub). Automatic from
// the first launch — a check every hour, a silent download, the install on
// the next quit or relaunch (project.yml: SUEnableAutomaticChecks,
// SUAutomaticallyUpdate, SUScheduledCheckInterval) — plus "Check for
// Updates…" in the app menu (MacCommands) and a switch in Settings ›
// Updates. The feed and the public EdDSA key come from the Info.plist; a
// build without the key (CI, a checkout without Local.xcconfig, a test
// host) leaves the updater off instead of letting Sparkle fail at launch.

import Foundation
import Sparkle

@MainActor @Observable
final class MacUpdater {
    /// True when the Info.plist carries a feed and a public key and Sparkle
    /// started; Settings hides its Updates section otherwise.
    private(set) var isEnabled = false
    /// The menu item's state: false while a check or an install is already
    /// under way (Sparkle's own `canCheckForUpdates`, mirrored through KVO).
    private(set) var canCheckForUpdates = false
    /// Settings › Updates › "Install updates automatically": Sparkle's
    /// background download-and-install. Off, it asks before each update.
    var installsAutomatically = false {
        didSet { controller.updater.automaticallyDownloadsUpdates = installsAutomatically }
    }

    private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil
    )
    private var observation: NSKeyValueObservation?

    init() {
        guard Self.isConfigured else { return }
        // A malformed key or feed is a build error, not a user's: Sparkle
        // logs it and shows its own "unable to check for updates" alert.
        controller.startUpdater()
        isEnabled = true
        installsAutomatically = controller.updater.automaticallyDownloadsUpdates
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    /// The app menu's item and the Settings button: Sparkle's standard
    /// sheet (the release notes, Install / Later), even when automatic.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// A feed and a real key in the Info.plist (`$(…)` is an unresolved
    /// xcconfig variable; CI writes the key empty), and not a test host.
    private static var isConfigured: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil { return false }
        let info = Bundle.main.infoDictionary ?? [:]
        guard let key = info["SUPublicEDKey"] as? String, !key.isEmpty, !key.hasPrefix("$("),
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty else { return false }
        return true
    }
}
