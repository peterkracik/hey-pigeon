// The "New mail (push)" setting: owns the toggle, the relay URL, the APNs
// device token and the engine's registration state. Off by default; the
// app is complete without it (background refresh + local notifications).
//
// What the relay learns is spelled out in relay/README.md; the one-line
// version is in the Settings footer.

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class PushController {
    private let engine: MailEngine
    private let defaults: UserDefaults
    /// Surfaces failures as a toast; set by AppModel.
    var notify: ((String) -> Void)?

    /// User intent. Persisted; the engine's own state is `status`.
    var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Keys.enabled) }
    }
    /// The relay to register with: fixed at build time (HEYPIGEON_RELAY_URL →
    /// Info.plist), never shown or edited in the UI. Empty in a build made
    /// without one, which disables the toggle.
    let relayURL: String
    /// True when the build carries a relay. Push then starts on — same
    /// footing as the baked OAuth client.
    var isBaked: Bool { !relayURL.isEmpty }
    /// Last APNs token the system gave us (hex). Re-registered whenever
    /// accounts change; iOS may rotate it at any launch.
    private(set) var deviceToken: String? {
        didSet { defaults.set(deviceToken, forKey: Keys.deviceToken) }
    }
    private(set) var status: PushState?
    private(set) var lastError: String?
    private(set) var busy = false

    private enum Keys {
        static let enabled = "push.enabled"
        static let deviceToken = "push.deviceToken"
    }

    /// Xcode builds get sandbox tokens, TestFlight / App Store builds
    /// production ones; the relay routes per token, so this must be right.
    static var environment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    init(engine: MailEngine, defaults: UserDefaults = .standard) {
        self.engine = engine
        self.defaults = defaults
        // Build-time relay (Info.plist ← Local.xcconfig HEYPIGEON_RELAY_URL).
        // An unset xcconfig key arrives as the literal "$(…)", same as
        // GoogleIOSClientID.
        let bakedRaw = ((Bundle.main.object(forInfoDictionaryKey: "HeyPigeonRelayURL") as? String) ?? "")
            .trimmingCharacters(in: .whitespaces)
        relayURL = bakedRaw.hasPrefix("https://") ? bakedRaw : ""
        // Default: on when the build knows its relay and the user has never
        // decided otherwise; off when there is nothing to register with.
        if let decided = defaults.object(forKey: Keys.enabled) as? Bool {
            enabled = decided && !relayURL.isEmpty
        } else {
            enabled = !relayURL.isEmpty
        }
        deviceToken = defaults.string(forKey: Keys.deviceToken)
        refreshStatus()
    }

    var canEnable: Bool { isBaked }

    func refreshStatus() {
        status = try? engine.pushStatus()
    }

    /// Ask iOS for a token (or a fresh copy of the current one). The answer
    /// arrives through AppDelegate → `tokenReceived`.
    func requestRegistration() {
        guard enabled, canEnable else { return }
        lastError = nil
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// The toggle. On: register with the system, which calls back with a
    /// token. Off: forget the device at the relay and stop every watch.
    func setEnabled(_ on: Bool) async {
        lastError = nil
        enabled = on
        if on {
            await ReminderScheduler.requestPermission()
            requestRegistration()
        } else {
            busy = true
            defer { busy = false }
            UIApplication.shared.unregisterForRemoteNotifications()
            do {
                try await engine.disablePush()
            } catch {
                lastError = error.localizedDescription
            }
            refreshStatus()
        }
    }

    func tokenReceived(_ hex: String) async {
        deviceToken = hex
        guard enabled, canEnable else { return }
        await register()
    }

    func registrationFailed(_ message: String) {
        let text = "Push registration failed: \(message)"
        lastError = text
        notify?(text)
    }

    /// Accounts were added or removed: a registration covers every account,
    /// so redo it with the token we have.
    func accountsChanged() async {
        guard enabled, canEnable, deviceToken != nil else { return }
        await register()
    }

    private func register() async {
        guard let token = deviceToken else { return }
        busy = true
        defer { busy = false }
        do {
            try await engine.registerPushToken(
                relayURL: relayURL,
                deviceToken: token,
                environment: Self.environment
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        refreshStatus()
    }
}
