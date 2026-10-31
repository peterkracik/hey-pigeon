// The app's one door to the platform: everything that differs between the
// iPhone, the iPad and the Mac sits behind these names, so a view or the
// model never imports UIKit or AppKit for a haptic, the keyboard, the
// clipboard, a system-settings link or "is the app in front". The iOS
// branch is what ships on the phone; the macOS branch is compiled by the
// native Mac app (macos-app/, docs/porting-macos-ipados.md). Keep both
// behaving the same from a feature file's point of view.

import AppIntents
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
typealias PlatformImage = UIImage
typealias PlatformFont = UIFont
#elseif canImport(AppKit)
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
typealias PlatformFont = NSFont
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
    /// switches live there). The Mac has no per-app page: Siri's own pane
    /// is where "Apple Intelligence & Siri" and app access are decided.
    static func openAppSettings() {
        #if canImport(UIKit)
        open(UIApplication.openSettingsURLString)
        #elseif canImport(AppKit)
        open("x-apple.systempreferences:com.apple.Siri-Settings.extension")
        #endif
    }

    /// The system's Notifications pane (the Mac's banners and badge switches
    /// live there; iOS keeps them on the app's own page).
    static func openNotificationSettings() {
        #if canImport(UIKit)
        open(UIApplication.openNotificationSettingsURLString)
        #elseif canImport(AppKit)
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #endif
    }

    /// Default Apps (iOS 18.3+), where the user picks the Email app. The Mac
    /// has no such page: the app asks the system to make it the handler of
    /// mailto: links itself, and macOS confirms with the user once.
    static func openDefaultApps() {
        #if canImport(UIKit)
        open(UIApplication.openDefaultApplicationsSettingsURLString)
        #elseif canImport(AppKit)
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto") { _ in }
        #endif
    }

    #if os(macOS)
    /// Whether this app is the Mac's mail handler right now (the Mac can
    /// read it, unlike iOS), so Settings can show a status line.
    static var isDefaultMailApp: Bool {
        guard let url = URL(string: "mailto:test@example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }
    #endif

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
    /// autocorrection, and the matching keyboard on iOS (an address field
    /// also tells the keyboard what it is, for the system's suggestions).
    @ViewBuilder
    func plainInput(_ kind: PlainInputKind = .text) -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(kind.keyboard)
            .textContentType(kind.contentType)
        #else
        autocorrectionDisabled()
        #endif
    }

    /// The keyboard goes away when the content scrolls (iOS); the Mac has no
    /// soft keyboard to dismiss.
    @ViewBuilder
    func dismissKeyboardOnScroll(_ mode: KeyboardScrollDismissal = .immediately) -> some View {
        #if os(iOS)
        switch mode {
        case .immediately: scrollDismissesKeyboard(.immediately)
        case .interactively: scrollDismissesKeyboard(.interactively)
        }
        #else
        self
        #endif
    }

    /// A pushed screen that hides the tab bar (the thread view puts its own
    /// glass bars in its place). The Mac window has no tab bar.
    @ViewBuilder
    func hidesTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    /// How big a sheet is: detents (and the grabber) on iOS, a window size
    /// on the Mac, where a sheet is as large as its content asks to be.
    @ViewBuilder
    func sheetSize(_ size: SheetSize, dragIndicator: Bool = true) -> some View {
        #if os(iOS)
        presentationDetents(size.detents)
            .presentationDragIndicator(dragIndicator ? .visible : .automatic)
        #else
        frame(minWidth: size.frame.width, idealWidth: size.frame.width,
              minHeight: size.frame.height, idealHeight: size.frame.height)
        #endif
    }

    /// A search field that is always on screen, under the title: the iOS
    /// navigation-bar drawer; the Mac puts it in the toolbar.
    @ViewBuilder
    func alwaysShownSearch(text: Binding<String>, prompt: String) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        #else
        searchable(text: text, placement: .toolbar, prompt: prompt)
        #endif
    }

    /// The phone's Search tab hides its navigation bar (the field lives in
    /// the tab bar, so an empty bar would only push the filters down);
    /// regular widths and the Mac keep theirs.
    @ViewBuilder
    func hidesNavigationBarInCompactWidth() -> some View {
        #if os(iOS)
        modifier(CompactNavigationBarHider())
        #else
        self
        #endif
    }

    /// iOS 26 view annotation: Siri's on-screen awareness sees this view as
    /// the entity ("mark these done"). The Mac has no on-screen Siri.
    @ViewBuilder
    func siriEntity(_ identifier: EntityIdentifier) -> some View {
        #if os(iOS)
        appEntityIdentifier(identifier)
        #else
        self
        #endif
    }

    /// The thread bars' hardware-keyboard keys on the iPad (e · h · n · s ·
    /// r · ⌘⌫). The Mac runs the same keys through its window's key map
    /// (macos-app WindowState.handle), where a bare letter never reaches a
    /// text field; a key equivalent on the button would take it from one.
    @ViewBuilder
    func threadKey(_ key: KeyEquivalent, modifiers: EventModifiers = []) -> some View {
        #if os(iOS)
        keyboardShortcut(key, modifiers: modifiers)
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct CompactNavigationBarHider: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        content.toolbarVisibility(sizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
    }
}
#endif

/// `dismissKeyboardOnScroll`'s two iOS behaviours.
enum KeyboardScrollDismissal {
    case immediately, interactively
}

/// `sheetSize`: the three sheet heights the app uses.
enum SheetSize {
    case medium, mediumOrLarge, large

    #if os(iOS)
    var detents: Set<PresentationDetent> {
        switch self {
        case .medium: [.medium]
        case .mediumOrLarge: [.medium, .large]
        case .large: [.large]
        }
    }
    #else
    /// The Mac sheet's size, in points.
    var frame: CGSize {
        switch self {
        case .medium: CGSize(width: 480, height: 420)
        case .mediumOrLarge: CGSize(width: 560, height: 560)
        case .large: CGSize(width: 680, height: 720)
        }
    }
    #endif
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

    /// Only an address field declares its content (the recipient fields'
    /// autofill); the others stay plain, as they were.
    var contentType: UITextContentType? {
        self == .email ? .emailAddress : nil
    }
    #endif
}
