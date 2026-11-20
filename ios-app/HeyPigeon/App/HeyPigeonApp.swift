import CoreSpotlight
import SwiftUI
import UIKit

@main
struct HeyPigeonApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    // APNs tokens and silent pushes arrive through UIKit (AppDelegate.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let engine = AppBootstrap.makeEngine(clientIdKey: "GoogleIOSClientID")
        let model = AppModel(engine: engine)
        _model = State(initialValue: model)
        AppModel.registerBackgroundRefresh(model)
        // The widget buttons reach the model (the shared AppBootstrap).
        AppBootstrap.installWidgetActions()
        // Spotlight asks the app for items it should re-index, and the
        // iOS 27 search tool reads full items back through the same door.
        SpotlightIndexer.installDelegate()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.textPrimary)
                .task {
                    await ReminderScheduler.requestPermission()
                    // With push on, iOS may have rotated the token since last launch.
                    model.push.requestRegistration()
                    await model.sync()
                }
                // heypigeon://thread/<id> · compose · folder/<name> — from a
                // widget, the Live Activity or the share extension — and
                // mailto: links, which iOS routes to the default mail app.
                .onOpenURL { url in
                    if let link = DeepLink(url: url) { model.handle(link) }
                }
                // A Spotlight (or Siri search) result of ours was tapped: the
                // indexed item is a thread or one of its messages
                // (`<threadId>#<messageId>`); either opens the thread.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
                    model.openThread(id: MailMessageEntity.threadId(of: id))
                }
                // Spotlight's "Search in Hey Pigeon" row (CoreSpotlightContinuation
                // in project.yml): the typed words continue in the search.
                .onContinueUserActivity(CSQueryContinuationActionType) { activity in
                    guard let query = activity.userInfo?[CSSearchQueryString] as? String else { return }
                    model.openSearch(query)
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Refocusing the app is the strongest "is there new mail?" signal.
                Task { await model.sync() }
                // The share sheet may have left a draft.
                model.adoptPendingShare()
                Task { await ReminderLiveActivityController.endLeftovers() }
            case .background:
                model.flushPendingSends()
                model.flushPendingPrefs()
                AppModel.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }
}

/// Root navigation: the three-tab bar (Inbox · Remind me · Need reply,
/// with Compose in the circle beside it; the search is pulled down over
/// a list) plus the app-wide sheets and the toast. The iPad has the same
/// root at every width: one list in a readable column and a thread in
/// its place, as on the phone and the Mac. Its three columns
/// (`Features/Pad/PadSplitView`) read as an ordinary mail client and are
/// no longer shown; the folders' drawer and the list's keys are rebuilt
/// from them next (docs/porting-macos-ipados.md).
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        withSheets(tabs)
    }

    /// The three tabs, on the phone and the iPad alike, and Compose in the
    /// circle beside them.
    /// The search is not one of them: it opens over a list (the field
    /// pulled down above it, MailListScreen), and the bar keeps that
    /// list's tab selected meanwhile (`listTab`). A tap on any tab leaves
    /// the search.
    private var tabs: some View {
        TabView(selection: Binding(
            get: { BarSlot.list(model.listTab) },
            set: { slot in
                switch slot {
                case .list(let tab): model.tab = tab
                // Never selected: the binding goes on answering with the
                // list, so the bar stays where it was under the composer.
                case .compose: model.composeDraft = SendDraft()
                }
            }
        )) {
            Tab(MainTab.inbox.title, systemImage: MainTab.inbox.systemImage, value: BarSlot.list(.inbox)) {
                MailListScreen(tab: .inbox)
            }
            .badge(model.counts["inbox"] ?? 0)
            Tab(MainTab.scheduled.title, systemImage: MainTab.scheduled.systemImage, value: BarSlot.list(.scheduled)) {
                MailListScreen(tab: .scheduled)
            }
            // Reminders whose time has passed, not every scheduled thread.
            .badge(model.dueCount)
            Tab(MainTab.needReply.title, systemImage: MainTab.needReply.systemImage, value: BarSlot.list(.needReply)) {
                MailListScreen(tab: .needReply)
            }
            .badge(model.needReplyCount)
            // Compose, under the thumb. The separate glass circle beside
            // the tab bar is the system's, and it draws one only for the
            // search role: so this is that tab with a pencil, and choosing
            // it opens the composer instead of a page (the binding above).
            Tab("Compose", systemImage: "square.and.pencil", value: BarSlot.compose, role: .search) {
                Color.clear
            }
        }
        // ⌘N, which the top bar's Compose button used to carry: on a
        // button that draws nothing, so it works wherever the focus is.
        .background {
            Button("Compose") { model.composeDraft = SendDraft() }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
        // Out of the search, however it was left (Cancel, a tab, a
        // notification's thread): the field hides again, so its words and
        // filters go with it.
        .onChange(of: model.tab) { old, _ in
            if old == .search { model.clearSearch() }
        }
        // The tab bar stays whole while the list scrolls: Inbox, Remind me
        // and Need reply are one tap away at any depth. What gives the rows
        // their room is the label bar over it, which folds to the label in
        // use (TriageSplitBar, ScrollCollapse).
    }
}

/// What the tab bar holds: a list's tab, or Compose — a button
/// in a tab's place, never the selection.
private enum BarSlot: Hashable {
    case list(MainTab)
    case compose
}

extension RootView {
    /// The app-wide sheets and the toast, over the tabs.
    private func withSheets<Content: View>(_ content: Content) -> some View {
        @Bindable var model = model
        return content
            .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
            .sheet(isPresented: $model.showSidebar, onDismiss: { Keyboard.dismiss() }) { SidebarSheet() }
            .sheet(isPresented: $model.showSettings, onDismiss: { Keyboard.dismiss(); model.settingsClosed() }) { SettingsView() }
            // Remind me, Add to bundle, the summary (Shared/RootChrome).
            // While the Bundles sheet is open it presents these itself
            // (AppModel.modal, BundleSheetPresenters).
            .sharedSheets(inBundles: false, dismissesKeyboard: true)
            .coverScreen(isPresented: $model.showBundles, onDismiss: { model.bundlesStartId = nil; model.bundlesStartInfoId = nil }) {
                BundlesSheet(initialBundleId: model.bundlesStartId)
            }
            // The composer as a dialog or full screen (its button switches).
            // Each presentation only clears the draft when it is the one in
            // use, so switching does not close the composer.
            .sheet(item: Binding(get: { model.composeFullScreen || model.showBundles ? nil : model.composeDraft },
                                 set: { if $0 == nil && !model.composeFullScreen { model.composeDraft = nil } }),
                   onDismiss: { Keyboard.dismiss() }) { draft in ComposeView(draft: draft) }
            .fullScreenCover(item: Binding(get: { model.composeFullScreen && !model.showBundles ? model.composeDraft : nil },
                                           set: { if $0 == nil && model.composeFullScreen { model.composeDraft = nil } }),
                             onDismiss: { Keyboard.dismiss() }) { draft in ComposeView(draft: draft) }
            .sheet(item: $model.askSheet) { p in AskSheet(question: p.question) }
            .sheet(item: $model.recentOpensSheet) { _ in RecentOpensView() }
            .overlay(alignment: .bottom) { ToastStack() }
            .disconnectedAlert()
    }
}
