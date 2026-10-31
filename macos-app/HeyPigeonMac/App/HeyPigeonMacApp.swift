// Hey Pigeon for the Mac: the iPhone app's model, engine, intents, Spotlight
// index, widget snapshot and AI layer (ios-app/HeyPigeon, compiled for macOS)
// under a Mac window — three columns (folders · threads · the open thread),
// the desktop's keyboard map, a menu bar, Settings (⌘,), an optional menu
// bar extra with the unread count, and a thread in its own window on Return.
// The Mac never suspends the app, so sync is a timer while it runs plus
// every activation (MacSyncLoop), and new-mail banners come from that
// timer's diff rather than a push relay.

import AppKit
import CoreSpotlight
import SwiftUI

/// The scene ids the app opens windows by.
enum MacWindows {
    static let main = "main"
    static let thread = "thread"
}

@main
struct HeyPigeonMacApp: App {
    @State private var model: AppModel
    // APNs tokens, silent pushes, notification taps and the Dock menu
    // arrive through AppKit (MacAppDelegate.swift).
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    /// Settings › Appearance › "Show in the menu bar".
    @AppStorage("menuBarExtra") private var menuBarExtra = true

    init() {
        let engine = Self.makeEngine()
        let model = AppModel(engine: engine)
        _model = State(initialValue: model)
        Self.installWidgetActions()
        // Spotlight asks the app for items it should re-index, and the
        // search tool reads full items back through the same door.
        SpotlightIndexer.installDelegate()
        MacSyncLoop.shared.start(model)
    }

    /// Widget buttons that reach the app as intents (Shortcuts can run
    /// them on the Mac too); the Mac widgets themselves use heypigeon://
    /// links, which land in `onOpenURL` below.
    private static func installWidgetActions() {
        WidgetActions.handler = { action in
            guard let model = AppModel.current else { return }
            switch action {
            case .markDone(let id):
                if let row = try? model.engine.threadRow(id: id), !row.isDone { model.markDone(row) }
            case .snooze(let id, let hours):
                model.snooze(threadId: id, hours: hours)
            case .open(let target):
                model.handle(DeepLink(target))
            case .cancelTriage:
                TriageAgent.current?.cancel()
            }
            try? await Task.sleep(for: .milliseconds(50))
            model.reload()
        }
    }

    private var scheme: ColorScheme? { Appearance(rawValue: appearance)?.scheme }

    var body: some Scene {
        WindowGroup(id: MacWindows.main) {
            MainWindow()
                .environment(model)
                .preferredColorScheme(scheme)
                .task {
                    await ReminderScheduler.requestPermission()
                    model.push.requestRegistration()
                    await model.sync()
                }
                // heypigeon://thread/<id> · compose · folder/<name> · done/<id>
                // · snooze/<id>/<h> from the widgets and the share extension,
                // and mailto: links once the app is the default mail app.
                .onOpenURL { url in
                    if let link = DeepLink(url: url) { model.handle(link) }
                }
                // A Spotlight result of ours was opened: a thread, or one of
                // its messages (`<threadId>#<messageId>`); either opens the thread.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    model.openThread(id: MailMessageEntity.threadId(of: id))
                }
                // Spotlight's "Search in Hey Pigeon" row: the words continue
                // in the list column's search field.
                .onContinueUserActivity(CSQueryContinuationActionType) { activity in
                    guard let query = activity.userInfo?[CSSearchQueryString] as? String else { return }
                    model.openSearch(query)
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands { MacCommands(model: model) }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Coming back to the app is the strongest "is there new mail?" signal.
                Task { await model.sync() }
                model.adoptPendingShare()
            case .background:
                model.flushPendingSends()
                model.flushPendingPrefs()
            default:
                break
            }
        }

        // Return (or "Open in New Window") puts a thread in its own window.
        WindowGroup("Thread", id: MacWindows.thread, for: String.self) { $threadId in
            ThreadWindow(threadId: threadId)
                .environment(model)
                .preferredColorScheme(scheme)
        }
        .defaultSize(width: 760, height: 760)

        // ⌘, — the same sections as the phone's Settings sheet, in a window.
        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(scheme)
        }

        MenuBarExtra(isInserted: $menuBarExtra) {
            MenuBarExtraView()
                .environment(model)
                .preferredColorScheme(scheme)
        } label: {
            MenuBarExtraLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)
    }

    /// Real engine unless the scheme asks for the mock (HEYPIGEON_MOCK=1) or
    /// no OAuth client id is configured — then the sample inbox, so the UI
    /// is always runnable (and CI builds without secrets).
    private static func makeEngine() -> MailEngine {
        let env = ProcessInfo.processInfo.environment
        let clientId = (Bundle.main.object(forInfoDictionaryKey: "GoogleMacClientID") as? String) ?? ""
        if env["HEYPIGEON_MOCK"] == "1" || clientId.isEmpty || clientId.hasPrefix("$(") {
            return MockEngine()
        }
        do {
            let dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("HeyPigeon", isDirectory: true)
            return try RustEngine(dataDir: dir, clientId: clientId)
        } catch {
            assertionFailure("engine failed to open: \(error)")
            return MockEngine()
        }
    }
}
