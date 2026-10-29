// The app's one door to the platform: everything that differs between the
// iPhone, the iPad and a future Mac build sits behind these names, so a
// view or the model never imports UIKit for a haptic, the keyboard, the
// clipboard, a system-settings link or "is the app in front". The iOS
// branch is what ships today; the macOS branch is the porting starting
// point (docs/porting-macos-ipados.md) and is not compiled by any target
// yet — keep it to plain AppKit so the port starts from something close.

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Which device

/// The device's everyday name, for copy such as "On this iPhone". Worked
/// out once, without UIKit (whose `UIDevice` is main-actor only): the Mac
/// first (Catalyst or an iPad app on Apple silicon), then the model
/// identifier — the simulator's comes from its environment.
enum Device {
    static let name: String = {
        #if os(macOS)
        return "Mac"
        #else
        let info = ProcessInfo.processInfo
        if info.isMacCatalystApp || info.isiOSAppOnMac { return "Mac" }
        return Device.name(forModel: info.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? Device.machine())
        #endif
    }()

    /// "iPad13,1" → "iPad", "iPhone17,2" → "iPhone"; the phone otherwise.
    static func name(forModel model: String) -> String {
        if model.hasPrefix("iPad") { return "iPad" }
        if model.hasPrefix("Mac") { return "Mac" }
        return "iPhone"
    }

    /// `hw.machine`, e.g. "iPhone17,2" ("arm64" in the simulator).
    private static func machine() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// MARK: - Colours

#if canImport(UIKit)
typealias PlatformColor = UIColor
#elseif canImport(AppKit)
typealias PlatformColor = NSColor
#endif

extension Color {
    /// A colour that follows light / dark mode.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

// MARK: - Keyboard, haptics, clipboard

/// The keyboard does not always go away on its own when a sheet closes or
/// a tab switches; this resigns whatever has focus.
@MainActor
enum Keyboard {
    static func dismiss() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #elseif canImport(AppKit)
        NSApp.keyWindow?.makeFirstResponder(nil)
        #endif
    }
}

/// Feedback for the gestures. A no-op where there is no Taptic Engine to
/// speak of (the iPad), and on the Mac but for the trackpad's alignment tick.
@MainActor
enum Haptics {
    static func archive() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    static func light() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    static func success() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    static func warning() {
        #if os(iOS)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        #endif
    }
}

@MainActor
enum Clipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

// MARK: - The app and the system

@MainActor
enum AppLifecycle {
    /// The app is in front and the user can see it: background work that
    /// only makes sense on screen (the archive walk, banners) checks this.
    static var isActive: Bool {
        #if canImport(UIKit)
        return UIApplication.shared.applicationState == .active
        #elseif canImport(AppKit)
        return NSApp.isActive
        #endif
    }
}

/// APNs registration (the optional push relay, PushController). The token
/// comes back through the app delegate.
@MainActor
enum RemoteNotifications {
    static func register() {
        #if canImport(UIKit)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif canImport(AppKit)
        NSApplication.shared.registerForRemoteNotifications()
        #endif
    }

    static func unregister() {
        #if canImport(UIKit)
        UIApplication.shared.unregisterForRemoteNotifications()
        #elseif canImport(AppKit)
        NSApplication.shared.unregisterForRemoteNotifications()
        #endif
    }
}

/// Doors into the system's Settings app.
@MainActor
enum SystemSettings {
    /// The system's page for this app (its Siri & Search and notification
    /// switches live there).
    static func openAppSettings() {
        #if canImport(UIKit)
        open(UIApplication.openSettingsURLString)
        #elseif canImport(AppKit)
        open("x-apple.systempreferences:com.apple.preference.notifications")
        #endif
    }

    /// Default Apps (iOS 18.3+), where the user picks the Email app; the
    /// app's own page when the system has no such link.
    static func openDefaultApps() {
        #if canImport(UIKit)
        open(UIApplication.openDefaultApplicationsSettingsURLString)
        #elseif canImport(AppKit)
        // macOS keeps the default mail reader in Mail's own settings.
        openAppSettings()
        #endif
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else { return }
        #if canImport(UIKit)
        UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
        #endif
    }
}

// MARK: - Toolbar placements

extension ToolbarItemPlacement {
    /// The leading end of the top bar on iOS / iPadOS; the navigation area
    /// on the Mac, where `.topBarLeading` does not exist.
    static var barLeading: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarLeading
        #else
        return .navigation
        #endif
    }

    /// The trailing end of the top bar on iOS / iPadOS; the primary action
    /// area on the Mac.
    static var barTrailing: ToolbarItemPlacement {
        #if os(iOS)
        return .topBarTrailing
        #else
        return .primaryAction
        #endif
    }
}

// MARK: - View modifiers that only exist on iOS

extension View {
    /// Inline navigation title (the iOS bar style the app uses everywhere);
    /// the Mac's title bar has no other style.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// An input for addresses, URLs or keys: no autocapitalization, no
    /// autocorrection, and the matching keyboard on iOS.
    @ViewBuilder
    func plainInput(_ kind: PlainInputKind = .text) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(kind.keyboard)
        #else
        autocorrectionDisabled()
        #endif
    }
}

/// What `plainInput` is for; picks the iOS keyboard.
enum PlainInputKind {
    case text, email, url

    #if os(iOS)
    var keyboard: UIKeyboardType {
        switch self {
        case .text: .default
        case .email: .emailAddress
        case .url: .URL
        }
    }
    #endif
}
