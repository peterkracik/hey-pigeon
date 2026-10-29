import SwiftUI

@main
struct HeyPigeonApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    // APNs tokens and silent pushes arrive through UIKit (AppDelegate.swift).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let engine = Self.makeEngine()
        let model = AppModel(engine: engine)
        _model = State(initialValue: model)
        AppModel.registerBackgroundRefresh(model)
        Self.installWidgetActions()
        // Spotlight asks the app for items it should re-index, and the
        // iOS 27 search tool reads full items back through the same door.
        SpotlightIndexer.installDelegate()
    }

    /// Widget buttons, Live Activity buttons and Controls run their intents
    /// in this process (Shared/WidgetShared/WidgetIntents.swift); this is
    /// where they reach the model. The snapshot and the Live Activity follow
    /// so the surface that was tapped shows the result at once.
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
            // The optimistic row change lands on the next main-actor turn.
            try? await Task.sleep(for: .milliseconds(50))
            model.reload()
            await ReminderLiveActivityController.sync(model)
        }
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
                // widget, the Live Activity or the share extension.
                .onOpenURL { url in
                    if let link = DeepLink(url: url) { model.handle(link) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Refocusing the app is the strongest "is there new mail?" signal.
                Task { await model.sync() }
                // The share sheet may have left a draft; a due reminder gets
                // its Live Activity (only the app in front can start one).
                model.adoptPendingShare()
                Task { await ReminderLiveActivityController.sync(model) }
            case .background:
                model.flushPendingSends()
                AppModel.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }

    /// Real engine unless the scheme asks for the mock (HEYPIGEON_MOCK=1) or
    /// no OAuth client id is configured — then the sample inbox, so the UI
    /// is always runnable.
    private static func makeEngine() -> MailEngine {
        let env = ProcessInfo.processInfo.environment
        let clientId = (Bundle.main.object(forInfoDictionaryKey: "GoogleIOSClientID") as? String) ?? ""
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

/// Root navigation: the four-tab bar (Inbox · Scheduled · Need reply ·
/// Search — the desktop rail) plus the app-wide sheets and the toast.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
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
        // Liquid Glass tab bar shrinks away while reading, back on scroll up.
        .tabBarMinimizeBehavior(.onScrollDown)
            .preferredColorScheme(Appearance(rawValue: appearance)?.scheme)
            .sheet(isPresented: $model.showSidebar, onDismiss: { Keyboard.dismiss() }) { SidebarSheet() }
            .sheet(isPresented: $model.showSettings, onDismiss: { Keyboard.dismiss() }) { SettingsView() }
            .sheet(item: $model.pendingRemind, onDismiss: { Keyboard.dismiss() }) { row in RemindSheet(row: row) }
            .sheet(item: $model.composeDraft, onDismiss: { Keyboard.dismiss() }) { draft in ComposeView(draft: draft) }
            .sheet(item: $model.summarySheet) { p in SummarySheet(presentation: p) }
            .sheet(item: $model.askSheet) { p in AskSheet(question: p.question) }
            .overlay(alignment: .bottom) { ToastView() }
            .alert(
                "Account disconnected",
                isPresented: Binding(get: { model.disconnectedAccountId != nil },
                                     set: { if !$0 { model.disconnectedAccountId = nil } })
            ) {
                Button("Reconnect") {
                    let id = model.disconnectedAccountId
                    Task { await model.addAccount(loginHint: id) }
                }
                Button("Later", role: .cancel) {}
            } message: {
                Text("\(model.disconnectedAccountId ?? "") needs to sign in again. Mail for it is stale until then.")
            }
    }
}

extension SendDraft: Identifiable {
    var id: String { draftKey }
}

/// Bottom toast with an optional Undo — the archive gesture's safety net.
struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: 12) {
                Text(toast.text).font(.subheadline.weight(.medium)).lineLimit(2)
                if let undo = toast.undo {
                    Button("Undo") { undo(); model.toast = nil }
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular.interactive(), in: .capsule)
            .padding(.bottom, 72) // clears the floating tab bar
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(5))
                if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
            }
        }
    }
}
