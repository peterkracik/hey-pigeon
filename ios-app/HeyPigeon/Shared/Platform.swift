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

/// Reduce Motion (Settings › Accessibility › Motion on the phone, System
/// Settings › Accessibility › Display on the Mac), for what the app
/// animates itself: the row that slides out on Mark done, the swipe's
/// spring back, the toast. Read where the animation starts, so a change
/// of the setting holds from the next gesture on. The Mac window's own
/// pages read the environment value instead (macos-app MainWindow).
@MainActor
enum Motion {
    static var isReduced: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isReduceMotionEnabled
        #elseif canImport(AppKit)
        return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }

    /// `animation`, or none while Reduce Motion is on: the change still
    /// happens, without the slide.
    static func animation(_ animation: Animation) -> Animation? {
        isReduced ? nil : animation
    }

    /// A transition that moves: under Reduce Motion `calm` (a fade) stands
    /// in for it.
    static func transition(_ moving: AnyTransition, calm: AnyTransition = .opacity) -> AnyTransition {
        isReduced ? calm : moving
    }
}

/// VoiceOver: whether it is running, and a line spoken without moving
/// its cursor (a toast — "Marked done" — which appears at the bottom of
/// the screen, far from where the user is).
@MainActor
enum VoiceOver {
    static var isRunning: Bool {
        #if canImport(UIKit)
        return UIAccessibility.isVoiceOverRunning
        #elseif canImport(AppKit)
        return NSWorkspace.shared.isVoiceOverEnabled
        #endif
    }

    static func announce(_ text: String) {
        guard isRunning else { return }
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: text)
        #elseif canImport(AppKit)
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
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

/// A little more time when the user leaves the app mid-way through
/// long work (the analysis pass): iOS grants a short while after the app
/// goes to the background, then `isExpired` turns true and the work stops
/// at its next check. Held while in front too — iOS only starts counting
/// once the app leaves. The Mac keeps apps running, so it never expires.
@MainActor
final class BackgroundGrace {
    private(set) var isExpired = false
    #if canImport(UIKit)
    private var id: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(_ name: String) {
        #if canImport(UIKit)
        // The expiration handler runs on the main thread, and the task must
        // end before it returns or iOS ends the process.
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
        #endif
    }

    func end() {
        isExpired = true
        #if canImport(UIKit)
        if id != .invalid {
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
        #endif
    }
}

/// The buttons a new-mail banner carries, on both platforms: Mark Done and
/// Remind Me in 1 Hour act without opening the app, Reply opens it on the
/// thread with the composer. Registered and acted on in NewMailNotifier
/// (`registerActions`, `perform`), from each platform's app delegate.
enum NotificationActions {
    static let done = "mail.done"
    static let remindInAnHour = "mail.remind.1h"
    static let reply = "mail.reply"
    /// The category a new-mail banner is filed under.
    static let newMailCategory = "mail.new"
    /// The category a due-reminder banner is filed under: the same buttons.
    static let reminderCategory = "mail.reminder"
}

/// An attachment out of the app: the Mac copies it into the Downloads
/// folder and shows it in the Finder. The phone has the share sheet in
/// Quick Look for that.
enum Downloads {
    static var isAvailable: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    enum Failure: LocalizedError {
        case unavailable
        var errorDescription: String? { "There is no Downloads folder here." }
    }

    /// Copy `file` into Downloads as `name` ("name 2.pdf" when taken) and
    /// reveal it. Returns where it went.
    @MainActor
    @discardableResult
    static func save(_ file: URL, as name: String) throws -> URL {
        #if os(macOS)
        let manager = FileManager.default
        guard let folder = manager.urls(for: .downloadsDirectory, in: .userDomainMask).first else { throw Failure.unavailable }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var n = 2
        while manager.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        try manager.copyItem(at: file, to: target)
        NSWorkspace.shared.activateFileViewerSelecting([target])
        return target
        #else
        throw Failure.unavailable
        #endif
    }
}

/// APNs registration (the optional push relay, PushController). The token
/// comes back through the app delegate.
@MainActor
enum RemoteNotifications {
    /// Whether this app can be woken by a push at all. The Mac build has
    /// no push entitlement (it would need a provisioning profile, and the
    /// app is signed with Developer ID alone): it syncs on a timer, and a
    /// push switch there could never be turned on.
    static var isSupported: Bool {
        #if os(macOS)
        false
        #else
        true
        #endif
    }

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

/// Web links from mail. Straight to the system, not SwiftUI's `openURL`:
/// that one may present the page inside the app, over the message, and a
/// mail client hands links to the user's default browser (DESIGN.md).
@MainActor
enum Browser {
    static func open(_ url: URL) {
        #if canImport(UIKit)
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        #elseif canImport(AppKit)
        NSWorkspace.shared.open(url)
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

// MARK: - The system's controls in the app's ink

/// What the system draws itself, taught the app's type and ink once at
/// launch: a navigation bar's title in the display face, and a segmented
/// control whose selected segment is ink rather than the system's white
/// tile (selection is ink everywhere else). The Mac has no such proxies
/// and needs none: its window draws its own tabs (`TabPill`) and names
/// its pages itself.
enum SystemChrome {
    @MainActor
    static func apply() {
        #if os(iOS)
        if let face = UIFont(name: "InstrumentSans-Bold", size: 17) {
            UINavigationBar.appearance().titleTextAttributes = [.font: face]
        }
        let segmented = UISegmentedControl.appearance()
        segmented.selectedSegmentTintColor = UIColor(Theme.textPrimary)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(Theme.onPrimary)], for: .selected)
        segmented.setTitleTextAttributes([.foregroundColor: UIColor(Theme.textSecondary)], for: .normal)
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

// MARK: - A readable column on a wide screen

/// How wide a column of mail may get on the iPad, where the phone's
/// edge-to-edge list and thread stretched across the whole screen. The
/// Mac has its own measure for its single-line rows (macos-app
/// `MacLayout.maxWidth`).
enum ReadableLayout {
    static let maxWidth: CGFloat = 760

    /// The margin on each side that centres a `maxWidth` column in a
    /// container this wide; none when it already fits.
    static func margin(in width: CGFloat) -> CGFloat {
        max(0, (width - maxWidth) / 2)
    }
}

extension View {
    /// Keeps a list's or a scroll view's content to a readable column on
    /// a regular-width iPad, centred, while the scroll view itself still
    /// spans the screen (a drag in the margin scrolls). The phone — and
    /// the iPad in a compact width — get the view untouched; so does the
    /// Mac, whose window lays its columns out itself.
    @ViewBuilder
    func readableColumn() -> some View {
        #if os(iOS)
        modifier(ReadableColumn())
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct ReadableColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        // Branch on the device, which never changes while the app runs,
        // not on the size class: an `if` on the size class would rebuild
        // the list or the thread (scroll position, an inline reply being
        // written) each time an iPad window is resized across it. It also
        // keeps a large phone in landscape, which is regular width too,
        // out of the column.
        if Device.name == "iPad" {
            content
                .contentMargins(.horizontal, sizeClass == .regular ? ReadableLayout.margin(in: width) : 0,
                                for: .scrollContent)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        } else {
            content
        }
    }
}
#endif

// MARK: - Small targets

extension View {
    /// A larger tap area around a small drawing (a chip's ×, a message's
    /// •••) without moving or resizing it: the padding widens what takes
    /// the tap, and the same padding taken off again leaves the layout as
    /// it was. Goes on a button's label. 44 pt is the phone's minimum.
    func tapArea(horizontal: CGFloat = 0, vertical: CGFloat = 0) -> some View {
        padding(.horizontal, horizontal).padding(.vertical, vertical)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontal).padding(.vertical, -vertical)
    }
}

// MARK: - The toast

/// Where the toast sits: above the phone's floating tab bar; near the
/// bottom edge of the Mac window.
enum ToastMetrics {
    #if os(iOS)
    static let bottomInset: CGFloat = 72
    /// With a thread open the tab bar is hidden and the thread's two
    /// glass bars stand in its place, taller than it: the toast sat on
    /// the triage bar.
    static let bottomInsetOverThread: CGFloat = 136
    static let verticalPadding: CGFloat = 12
    #else
    static let bottomInset: CGFloat = 18
    /// The Mac's thread bar is one small panel: the toast stays where it is.
    static let bottomInsetOverThread: CGFloat = 18
    static let verticalPadding: CGFloat = 11
    #endif

    /// How far up from the bottom edge the toast sits.
    static func bottomInset(threadOpen: Bool) -> CGFloat {
        threadOpen ? bottomInsetOverThread : bottomInset
    }
}

extension View {
    /// The toast's surface: an ink capsule on the phone and the Mac
    /// alike, with one soft shadow under it. It says what just happened
    /// and offers the way back, so it is the one thing on the screen
    /// drawn in solid ink that is not a button; its words are
    /// `onPrimary` and its Undo `onPrimaryPink` (RootChrome's ToastStack).
    func toastSurface() -> some View {
        background(Theme.textPrimary, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    /// The toast's Undo: the phone's text button as it is; plain on the
    /// Mac, where a default button draws a bezel.
    @ViewBuilder
    func toastButton() -> some View {
        #if os(iOS)
        self
        #else
        buttonStyle(.plain)
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

    /// A screen that covers the whole window on iOS (the Bundles screen:
    /// a sheet left it looking like a dialog); on the Mac a sheet, which
    /// is a window of its own. (The Mac window shows Bundles as a page of
    /// itself instead, `BundlesPage`, so only the phone's root uses this.)
    @ViewBuilder
    func coverScreen<Content: View>(isPresented: Binding<Bool>, onDismiss: @escaping () -> Void,
                                    @ViewBuilder content: @escaping () -> Content) -> some View {
        #if os(iOS)
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss, content: content)
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
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

    /// How big a popover's content is (the translation panel). A popover
    /// sizes to its content's ideal size, so the Mac and the iPad get this
    /// frame; on the phone the popover opens as a sheet, which takes the
    /// detents and the width the sheet proposes instead.
    @ViewBuilder
    func panelSize(_ size: SheetSize) -> some View {
        #if os(iOS)
        presentationCompactAdaptation(.sheet)
            .presentationDetents(size.detents)
            .presentationDragIndicator(.visible)
            .frame(idealWidth: size.panel.width, maxWidth: .infinity, idealHeight: size.panel.height, maxHeight: .infinity)
        #else
        frame(width: size.panel.width, height: size.panel.height)
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

    /// The phone's search field, in the navigation bar's drawer and
    /// always shown: it is put on the search's own pane, which is on
    /// screen only while the search is up (a short pull down on a list
    /// opens it — `PullDown`). The drawer is named: left to the system
    /// the field goes to the bottom toolbar on the phone. Nothing on the
    /// Mac, whose search is its own panel.
    @ViewBuilder
    func shownSearch(text: Binding<String>, isPresented: Binding<Bool>, prompt: String) -> some View {
        #if os(iOS)
        searchable(text: text, isPresented: isPresented,
                   placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
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

    /// A page pushed in a stack whose Back is the window's own toolbar
    /// item on the Mac (macos-app MainToolbar: at the content column's
    /// leading end, where the stack's own sat beside the traffic lights,
    /// over the sidebar); the phone keeps the navigation bar's.
    @ViewBuilder
    func backInWindowToolbar() -> some View {
        #if os(macOS)
        navigationBarBackButtonHidden(true)
        #else
        self
        #endif
    }

    /// The thread's Reply pill: the phone's glass capsule; on the Mac an
    /// outlined capsule, as the window's pills are (`MacPillButtonStyle`).
    /// The Mac does not draw the pill today — its Reply · Reply all ·
    /// Forward are at the last message's foot (`ThreadReplyFoot`) — so
    /// this is what it would stand on if it did.
    @ViewBuilder
    func replyPillSurface() -> some View {
        #if os(iOS)
        glassEffect(.regular, in: .capsule)
        #else
        background(Capsule().strokeBorder(Theme.textPrimary, lineWidth: 1))
        #endif
    }

    /// The thread's floating bar: the phone's glass capsule; on the Mac a
    /// paper panel (the raised paper, a hairline, one soft shadow) —
    /// glass stretched across the thread refracted the message under it
    /// into a smear. The bar floats over the messages and holds none, so
    /// its shadow falls on no web view.
    @ViewBuilder
    func floatingBar() -> some View {
        #if os(iOS)
        glassEffect(.regular, in: .capsule)
        #else
        background(MacTheme.panel, in: Capsule())
            .overlay(Capsule().strokeBorder(MacTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 2)
        #endif
    }

    /// A button in the thread's bar: plain on the phone's glass; on the
    /// Mac a square that takes the sunken grey under the pointer, as the
    /// window's icon buttons do (a plain button there gives no sign that
    /// it is one).
    @ViewBuilder
    func barButton() -> some View {
        #if os(iOS)
        buttonStyle(.plain)
        #else
        buttonStyle(MacBarButtonStyle())
        #endif
    }
}

/// How the thread's chrome is laid out: the phone's bars, or the Mac
/// window's.
enum ThreadChrome {
    #if os(iOS)
    /// The names are the navigation bar's principal item.
    static let titleInBar = true
    /// Two full-width glass capsules at the bottom: Reply with the AI
    /// circle beside it, then the triage bar.
    static let oneBar = false
    /// Reply · Reply all · Forward are the Reply pill's, over the triage bar.
    static let replyAtFoot = false
    /// The messages run edge to edge, flat: no card, no inset, square.
    static let cardInset: CGFloat = 0
    static let cardRadius: CGFloat = 0
    /// The subject's and the chips' margin: the messages' own.
    static let headerInset: CGFloat = 16
    /// Behind the thread; a closed message sinks into it, the open one
    /// sits on the card surface, as the list's read and unread rows do.
    static let page = Theme.canvas
    static let closedRow = Theme.canvas
    static let openRow = Theme.card
    /// A message's ••• as drawn (`tapArea` makes it 44 pt to the finger).
    static let actionsSize = CGSize(width: 28, height: 22)
    #else
    /// The window's toolbar names the thread itself (macos-app
    /// MainToolbar), after its Back: a principal item there is a bordered
    /// pill in the middle of the window, half over the sidebar.
    static let titleInBar = false
    /// One panel as wide as its contents, in the middle of the bottom
    /// edge: the triage buttons. The phone's two capsules, stacked and
    /// stretched across the thread, read as a smear of the message under
    /// them.
    static let oneBar = true
    /// Reply · Reply all · Forward are pills at the foot of the last
    /// message (`ThreadReplyFoot`), as under a row's preview in the
    /// list; the floating panel keeps the triage alone.
    static let replyAtFoot = true
    /// The messages stand straight on the paper, as wide as the reading
    /// column and square: no card, so no inset and no corners
    /// (`threadCard`, `rowShape`).
    static let cardInset: CGFloat = 0
    static let cardRadius: CGFloat = 0
    /// The subject's and the marks' margin: a message's own padding, so
    /// they start where the messages' text does.
    static let headerInset: CGFloat = 16
    /// One surface: the thread, its closed messages and its open ones
    /// are the paper, and the hairlines part them.
    static let page = Theme.canvas
    static let closedRow = Theme.canvas
    static let openRow = Theme.canvas
    /// A message's •••: the square of a row's own button
    /// (`IconButton.Size.small`).
    static let actionsSize = CGSize(width: 26, height: 26)
    #endif

    /// The surface of one row of the thread's messages: square, on the
    /// phone and on the Mac alike (`cardRadius` is 0 on both: the
    /// messages are ruled, not carded). The rows still carry their shape
    /// themselves — were they ever rounded again, it would be here and
    /// not by a clip, because a clip, like a shadow, would lie over the
    /// web view of every message in it.
    static func rowShape(first: Bool, last: Bool) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: first ? cardRadius : 0, bottomLeadingRadius: last ? cardRadius : 0,
                               bottomTrailingRadius: last ? cardRadius : 0, topTrailingRadius: first ? cardRadius : 0,
                               style: .continuous)
    }
}

extension View {
    /// The thread's reading column on the Mac: `MacLayout.readingWidth`,
    /// in the middle of whatever holds the thread (the window, the
    /// reading pane, a thread window, the Bundles page) — a line of mail
    /// ran the list's whole 1120 pt. The iPad has `readableColumn` for
    /// the same width; the phone is as wide as it is.
    @ViewBuilder
    func threadColumn() -> some View {
        #if os(macOS)
        frame(maxWidth: MacLayout.readingWidth).frame(maxWidth: .infinity)
        #else
        self
        #endif
    }

    /// What holds the thread's messages. No card on any platform (the
    /// name is from when the Mac had one): the Mac's rows stand straight
    /// on the paper, as wide as the reading column (`cardInset` is 0),
    /// with nothing painted behind them — each rules itself along its
    /// bottom edge (ThreadView's `MessageRow.ruled`). The phone's and the
    /// iPad's run edge to edge. No shadow and no clip, here or ever: both
    /// would fall on the web view of every message.
    @ViewBuilder
    func threadCard() -> some View {
        #if os(macOS)
        padding(.horizontal, ThreadChrome.cardInset)
        #else
        background(Theme.separator.opacity(0.6))
        #endif
    }

    /// A message row's surface colour: in the row's shape on the Mac
    /// (square, as `rowShape` is now); the phone's plain fill, which
    /// also runs under the safe area's sides in landscape, as it always
    /// did.
    @ViewBuilder
    func threadRowSurface(_ color: Color, in shape: UnevenRoundedRectangle) -> some View {
        #if os(macOS)
        background(color, in: shape)
        #else
        background(color)
        #endif
    }

    /// The pointer's tint on a row of the thread that a click opens (a
    /// closed message, the fold), as on a row of the Mac's list. Goes
    /// under the row's own surface colour, in the row's shape. Nothing
    /// on a touch screen.
    @ViewBuilder
    func threadRowHover(_ enabled: Bool = true,
                        in shape: UnevenRoundedRectangle = ThreadChrome.rowShape(first: false, last: false)) -> some View {
        #if os(macOS)
        modifier(MacHoverTint(color: MacTheme.hover, shape: shape, enabled: enabled))
        #else
        self
        #endif
    }

    /// The pointer's tint behind a small icon control of the thread (a
    /// message's •••): the rounded square of the Mac's row buttons.
    @ViewBuilder
    func threadIconHover() -> some View {
        #if os(macOS)
        modifier(MacHoverTint(color: MacTheme.selected, shape: RoundedRectangle(cornerRadius: 6, style: .continuous),
                              enabled: true))
        #else
        self
        #endif
    }
}

#if os(macOS)
/// A fill behind a view while the pointer is over it.
private struct MacHoverTint<S: Shape>: ViewModifier {
    let color: Color
    let shape: S
    let enabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering && enabled ? color : Color.clear, in: shape)
            .onHover { hovering = $0 }
    }
}
#endif

/// Reply · Reply all · Forward at the foot of the thread's last message
/// on the Mac: the pills under a row's preview in the list (macos-app
/// `PillButton`) — Reply the ink one, the thread's one ink action, the
/// other two outlined. Nothing on the phone and the iPad, whose Reply
/// pill floats over the triage bar.
struct ThreadReplyFoot: View {
    let onAction: (ReplyKind) -> Void

    var body: some View {
        #if os(macOS)
        HStack(spacing: 6) {
            ForEach(ReplyKind.allCases) { kind in
                PillButton(title: kind.title, systemImage: kind.systemImage, ink: kind == .reply) { onAction(kind) }
            }
            Spacer(minLength: 0)
        }
        #else
        EmptyView()
        #endif
    }
}

/// A message body's type. The phone and the iPad follow Dynamic Type;
/// the Mac, whose body text style is 13 pt, reads mail at 15 on a line
/// half as tall again — the measure of a 760 pt column.
enum MailTypography {
    #if os(macOS)
    /// The body size and its line height, as a multiple.
    static let bodySize: CGFloat = 15
    static let lineHeight: CGFloat = 1.5
    /// The `font` declarations of the page a message's HTML is shown in
    /// (`MailDocument.wrap`). Mail that sets its own sizes keeps them.
    static let bodyCSS = "font: 15px/1.5 -apple-system, system-ui;"
    #else
    static let bodyCSS = "font: -apple-system-body; font-family: -apple-system, system-ui;"
    #endif

    /// The font of plain-text mail: the text style's on iOS; on the Mac
    /// the body's 15 pt, and the list's 13 for the quoted part (the
    /// styles themselves are 13 and 11 there).
    static func font(_ style: PlatformFont.TextStyle) -> PlatformFont {
        #if os(macOS)
        return .systemFont(ofSize: style == .body ? bodySize : 13)
        #else
        return .preferredFont(forTextStyle: style)
        #endif
    }

    /// The paragraph style that gives plain-text mail the HTML body's
    /// line height on the Mac; nil where the font's own is right.
    static func paragraphStyle(for font: PlatformFont) -> NSParagraphStyle? {
        #if os(macOS)
        let natural = font.ascender - font.descender + font.leading
        let style = NSMutableParagraphStyle()
        style.lineSpacing = max(0, font.pointSize * lineHeight - natural)
        return style
        #else
        return nil
        #endif
    }
}

#if os(macOS)
/// The thread bar's button: a square that takes the sunken grey under
/// the pointer and dims while pressed or disabled.
struct MacBarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Square(configuration: configuration)
    }

    /// Hover is state of its own, which a style's `makeBody` cannot hold.
    private struct Square: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering && isEnabled ? Theme.sunken : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .onHover { hovering = $0 }
        }
    }
}
#endif

/// How the composer's full-screen switch works here. The phone swaps a
/// sheet for a full-screen cover, so the composer is closed and opened
/// again with what was typed; the Mac resizes the same sheet.
enum ComposePresentation {
    #if os(iOS)
    static let switchReopens = true
    /// No send-later on the phone: the message would wait for the app to
    /// run again, and iOS decides when that is — it could leave hours
    /// after the time picked. The Mac's app is open at its desk all day.
    static let offersSendLater = false
    static let offersSnippets = true
    /// A reply opens the phone's composer sheet.
    static let inlineReplies = false
    /// Return in the Subject field ends editing, as it always did.
    static let subjectReturnMovesToBody = false
    #else
    static let switchReopens = false
    /// The Mac's composer has the send-later clock beside Send; both
    /// have the snippets menu.
    static let offersSendLater = true
    static let offersSnippets = true
    /// The Mac writes a reply under its thread (ThreadView's inline
    /// composer, ComposeView's `inline`), as Superhuman does; the sheet
    /// stays for a new message, a forward, and a reply pulled out into a
    /// window (`AppModel.composeDetached`).
    static let inlineReplies = true
    /// Return in the Subject field moves on to the body.
    static let subjectReturnMovesToBody = true
    #endif
}

/// `dismissKeyboardOnScroll`'s two iOS behaviours.
enum KeyboardScrollDismissal {
    case immediately, interactively
}

/// `sheetSize`: the three sheet heights the app uses.
enum SheetSize {
    case medium, mediumOrLarge, large

    /// The same size as a popover (`panelSize`), in points.
    var panel: CGSize {
        switch self {
        case .medium: CGSize(width: 380, height: 340)
        case .mediumOrLarge: CGSize(width: 440, height: 480)
        case .large: CGSize(width: 520, height: 620)
        }
    }

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

// MARK: - The composer's chrome

extension View {
    /// Text fields without the Mac's bezel and focus ring, as the phone's
    /// fields are.
    @ViewBuilder
    func borderlessFields() -> some View {
        #if os(macOS)
        textFieldStyle(.plain).focusEffectDisabled()
        #else
        self
        #endif
    }

    /// A text button inside the composer's fields ("Cc/Bcc"): the
    /// phone's as it is; plain on the Mac, where a default button draws
    /// a bezel.
    @ViewBuilder
    func composeTextButton() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// A menu that shows its label only: no Mac pop-up bezel or second
    /// chevron (the label draws its own).
    @ViewBuilder
    func labelOnlyMenu() -> some View {
        #if os(macOS)
        // .plain unless a style closer to the menu says otherwise
        // (`.pillButton().labelOnlyMenu()` keeps the pill).
        menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain)
        #else
        self
        #endif
    }

    /// The phone's glass button; on the Mac the window's flat pill (a glass
    /// button there is a bordered white box): an ink capsule for the main
    /// action, an outlined one for every other (`MacPillButtonStyle`).
    @ViewBuilder
    func pillButton(prominent: Bool = false) -> some View {
        #if os(iOS)
        if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        #else
        buttonStyle(MacPillButtonStyle(prominent: prominent))
        #endif
    }

    /// An icon button of the composer's footer (attach, Aa, the AI,
    /// discard, More): the phone's glass circle; on the Mac a bare glyph
    /// that tints under the pointer, as a bar's buttons do. As outlined
    /// capsules, which is what a plain pill is there, a row of them
    /// beside Send read as six more actions of its weight.
    @ViewBuilder
    func composeIconButton() -> some View {
        #if os(iOS)
        buttonStyle(.glass)
        #else
        buttonStyle(MacBarButtonStyle())
        #endif
    }

    /// The composer's scroll view opens at its end when `on`: on the Mac a
    /// reply sits under the thread's messages, as in Superhuman, and the
    /// draft is what the sheet opens on; the phone keeps the thread under
    /// its editor and opens at the fields.
    @ViewBuilder
    func composeScrollsToEnd(_ on: Bool) -> some View {
        #if os(macOS)
        defaultScrollAnchor(on ? .bottom : nil)
        #else
        self
        #endif
    }

    /// The composer's title, close and size buttons: the phone's navigation
    /// bar; on the Mac a header row at the top — a Mac sheet puts toolbar
    /// items in a bar along its bottom. The Mac's row stands on the
    /// sheet's raised paper, its two buttons outlined pills, and ends with
    /// the rule that opens the fields under it.
    @ViewBuilder
    func composeChrome(title: String, fullScreen: Bool, close: @escaping () -> Void,
                       toggleFullScreen: @escaping () -> Void) -> some View {
        let sizeIcon = fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right"
        let sizeLabel = fullScreen ? "Show as a window" : "Full screen"
        #if os(iOS)
        navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { close() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close and save draft")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleFullScreen() } label: { Image(systemName: sizeIcon) }
                        .help(sizeLabel)
                        .accessibilityLabel(sizeLabel)
                }
            }
            // The sheet leaves by its X only: a scroll back up through the
            // message, carried past the top, used to pull the sheet down
            // and close the draft being written.
            .interactiveDismissDisabled()
        #else
        safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button { close() } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                        .pillButton()
                        .keyboardShortcut(.cancelAction)
                        .help("Close and save the draft (Esc)")
                        .accessibilityLabel("Close and save draft")
                    Spacer()
                    Text(title).font(Theme.sans(size: 14, weight: .bold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { toggleFullScreen() } label: { Image(systemName: sizeIcon).font(.system(size: 12, weight: .semibold)) }
                        .pillButton()
                        .help(sizeLabel)
                        .accessibilityLabel(sizeLabel)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                // The fields are a section with no name: they open with
                // the rule alone, in from the edges as their hairlines
                // are. (The phone's fields draw theirs under the system's
                // bar; here the header is the app's, and holds it.)
                SectionRule().padding(.horizontal, 16)
            }
            // The sheet's own surface (ComposeView's), so what scrolls
            // under the header does not show through it.
            .background(Theme.raised)
        }
        #endif
    }
}

#if os(macOS)
/// The Mac's pill. `prominent` is the main action, one a screen: an ink
/// capsule with the paper's colour for its words. Every other pill is
/// the ink as a hairline outline with no fill, the paper showing
/// through. Both dim while pressed or disabled.
struct MacPillButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.onPrimary : Theme.textPrimary)
            .background(prominent ? Theme.textPrimary : Color.clear, in: Capsule())
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.textPrimary, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}
#endif

/// Pages the user swipes between on iOS (a paged TabView with no dots);
/// the Mac shows the selected page, switched by the control above it.
struct SwipePages<Page: Hashable, Content: View>: View {
    @Binding var selection: Page
    let pages: [Page]
    @ViewBuilder let content: (Page) -> Content

    var body: some View {
        #if os(iOS)
        TabView(selection: $selection) {
            ForEach(pages, id: \.self) { page in content(page).tag(page) }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        #else
        content(selection)
        #endif
    }
}

/// A coloured dot for a menu item. A menu draws an SF Symbol as a
/// template in its own ink and ignores the symbol's colour, so the dot
/// is made as a picture that keeps its colour (UIKit's "always
/// original"), resolved for the appearance it is shown in. The Mac's
/// menus take a symbol's palette as it is.
enum MenuDot {
    static func image(_ color: Color, checked: Bool, scheme: ColorScheme) -> Image {
        let name = checked ? "checkmark.circle.fill" : "circle.fill"
        #if canImport(UIKit)
        let traits = UITraitCollection(userInterfaceStyle: scheme == .dark ? .dark : .light)
        let tint = UIColor(color).resolvedColor(with: traits)
        if let symbol = UIImage(systemName: name)?.withTintColor(tint, renderingMode: .alwaysOriginal) {
            return Image(uiImage: symbol)
        }
        return Image(systemName: name)
        #else
        return Image(systemName: name)
        #endif
    }
}
