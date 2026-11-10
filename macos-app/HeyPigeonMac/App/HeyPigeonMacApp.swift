// Hey Pigeon for the Mac: the iPhone app's model, engine, intents, Spotlight
// index, widget snapshot and AI layer (ios-app/HeyPigeon, compiled for macOS)
// under a Mac window in the first desktop client's shape (the standard
// unified toolbar with no title, the folders in a sidebar, single-line
// rows that open in place, a full thread or Settings in the list's
// place), the
// desktop's keyboard map, a menu bar, an optional menu
// bar extra with the unread count, and a thread in its own window on ⌘↩.
// The Mac never suspends the app, so sync is a timer while it runs plus
// every activation (MacSyncLoop), and new-mail banners come from that
// timer's diff rather than a push relay. The app updates itself from the
// builds publish-macos puts on GitHub (MacUpdater).

import AppKit
import CoreSpotlight
import SwiftUI

/// The scene ids the app opens windows by.
enum MacWindows {
    static let main = "main"
    static let thread = "thread"
    /// The defaults key of View › Reading Pane.
    static let readingPaneKey = "readingPane"
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
    /// Sparkle, started once for the process (MacUpdater.swift).
    private let updater = MacUpdater()

    init() {
        let engine = AppBootstrap.makeEngine(clientIdKey: "GoogleMacClientID")
        let model = AppModel(engine: engine)
        _model = State(initialValue: model)
        // The widget buttons reach the model (the shared AppBootstrap).
        AppBootstrap.installWidgetActions()
        // Spotlight asks the app for items it should re-index, and the
        // search tool reads full items back through the same door.
        SpotlightIndexer.installDelegate()
        MacSyncLoop.shared.start(model)
    }

    private var scheme: ColorScheme? { Appearance(rawValue: appearance)?.scheme }

    var body: some Scene {
        WindowGroup(id: MacWindows.main) {
            MainWindow()
                .environment(model)
                .environment(updater)
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
        .defaultSize(width: 1100, height: 760)
        // The standard unified toolbar, no title: MainToolbar's items sit
        // beside the traffic lights, as in every Mac app.
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { MacCommands(model: model, updater: updater) }
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

        // ⌘↩ (or "Open in New Window") puts a thread in its own window.
        WindowGroup("Thread", id: MacWindows.thread, for: String.self) { $threadId in
            ThreadWindow(threadId: threadId)
                .environment(model)
                .preferredColorScheme(scheme)
        }
        .defaultSize(width: 760, height: 760)

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
}
