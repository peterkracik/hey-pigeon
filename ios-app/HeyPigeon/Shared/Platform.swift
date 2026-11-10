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

    /// The thread's Reply pill: the phone's glass capsule; on the Mac the
    /// window's sunken pill (the composer's buttons), inside the bar's card.
    @ViewBuilder
    func replyPillSurface() -> some View {
        #if os(iOS)
        glassEffect(.regular, in: .capsule)
        #else
        background(Theme.sunken, in: Capsule())
        #endif
    }

    /// The thread's floating bar: the phone's glass capsule; on the Mac a
    /// flat card with a hairline and a soft shadow — glass stretched across
    /// the thread refracted the message under it into a smear.
    @ViewBuilder
    func floatingBar() -> some View {
        #if os(iOS)
        glassEffect(.regular, in: .capsule)
        #else
        background(Theme.card, in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.separator, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
        #endif
    }

    /// A button in the thread's bar: plain on the phone's glass; on the
    /// Mac a square that tints under the pointer, as the window's icon
    /// buttons do (a plain button there gives no sign that it is one).
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
    #else
    /// The window's toolbar names the thread itself (macos-app
    /// MainToolbar), after its Back: a principal item there is a bordered
    /// pill in the middle of the window, half over the sidebar.
    static let titleInBar = false
    /// One card as wide as its contents, in the middle of the bottom
    /// edge: the Reply pill, the AI circle, a hairline, the triage
    /// buttons. The phone's two capsules, stacked and stretched across
    /// the thread, read as a smear of the message under them.
    static let oneBar = true
    #endif
}

#if os(macOS)
/// The thread bar's button: a square that tints under the pointer and
/// dims while pressed or disabled.
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
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    /// button there is a bordered white box).
    @ViewBuilder
    func pillButton(prominent: Bool = false) -> some View {
        #if os(iOS)
        if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        #else
        buttonStyle(MacPillButtonStyle(prominent: prominent))
        #endif
    }

    /// The composer's scroll view opens at its end when `on`: on the Mac a
    /// reply sits under the thread's messages, as in Superhuman, and the
    /// draft is what the sheet opens on; the phone's composer has nothing
    /// above its fields.
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
    /// items in a bar along its bottom.
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
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Button { toggleFullScreen() } label: { Image(systemName: sizeIcon).font(.system(size: 12, weight: .semibold)) }
                        .pillButton()
                        .help(sizeLabel)
                        .accessibilityLabel(sizeLabel)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
            }
            .background(Theme.canvas)
        }
        #endif
    }
}

#if os(macOS)
/// The Mac's pill: the sunken fill (or the primary colour for the main
/// action), no border, dimmed when disabled.
struct MacPillButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10).padding(.vertical, 7)
            .foregroundStyle(prominent ? Theme.onPrimary : Theme.textPrimary)
            .background(prominent ? Theme.textPrimary : Theme.sunken, in: Capsule())
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
