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
                // in project.yml): the typed words continue in the Search tab.
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

/// Root navigation: the four-tab bar (Inbox · Scheduled · Need reply ·
/// Search — the desktop rail) plus the app-wide sheets and the toast. An
/// iPad at regular width shows three columns instead (PadSplitView); the
/// sheets and the toast are the same over either.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    /// What the columns show. Kept here, not in PadSplitView: resizing an
    /// iPad window across the width where the layouts swap rebuilds the
    /// one shown, and the open thread must not close with it.
    @State private var pad = PadState()

    /// The split layout: an iPad wide enough for columns. Never a phone —
    /// the large ones are "regular" in landscape too — and not an iPad in
    /// Slide Over or a narrow split, which get the phone's layout.
    private var showsColumns: Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }

    var body: some View {
        withSheets(Group {
            if showsColumns {
                PadSplitView(state: pad)
            } else {
                tabs
            }
        })
        // Narrowed to the tabs with a thread open: the stack pushes it
        // (the same request a notification makes).
        .onChange(of: showsColumns) { _, columns in
            if !columns, let open = pad.openRow { model.openThread(id: open.id) }
        }
    }

    /// The phone's four tabs (an iPad in a narrow window has them too).
    private var tabs: some View {
        @Bindable var model = model
        return TabView(selection: $model.tab) {
            Tab(MainTab.inbox.title, systemImage: MainTab.inbox.systemImage, value: MainTab.inbox) {
                MailListScreen(tab: .inbox)
            }
            .badge(model.counts["inbox"] ?? 0)
            Tab(MainTab.scheduled.title, systemImage: MainTab.scheduled.systemImage, value: MainTab.scheduled) {
                MailListScreen(tab: .scheduled)
            }
            // Reminders whose time has passed, not every scheduled thread.
            .badge(model.dueCount)
            Tab(MainTab.needReply.title, systemImage: MainTab.needReply.systemImage, value: MainTab.needReply) {
                MailListScreen(tab: .needReply)
            }
            .badge(model.needReplyCount)
            // Search role: the system renders it as the separate glass circle
            // next to the tab bar and morphs it into the search field.
            Tab(value: MainTab.search, role: .search) {
                SearchScreen()
            }
        }
        // The tab bar stays whole while the list scrolls: Inbox, Remind me
        // and Need reply are one tap away at any depth. What gives the rows
        // their room is the label bar over it, which folds to the label in
        // use (TriageSplitBar, ScrollCollapse).
    }
}

extension RootView {
    /// The app-wide sheets and the toast, over the tabs or the columns.
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
            .coverScreen(isPresented: $model.showBundles, onDismiss: { model.bundlesStartId = nil }) {
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
            .overlay(alignment: .bottom) { ToastStack() }
            .disconnectedAlert()
    }
}
