import SwiftUI

@main
struct HeyPigeonApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let engine = Self.makeEngine()
        let model = AppModel(engine: engine)
        _model = State(initialValue: model)
        AppModel.registerBackgroundRefresh(model)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.textPrimary)
                .task {
                    await ReminderScheduler.requestPermission()
                    await model.sync()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Refocusing the app is the strongest "is there new mail?" signal.
                Task { await model.sync() }
            case .background:
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

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.tab) {
            MailListScreen(tab: .inbox)
                .tabItem { Label(MainTab.inbox.title, systemImage: MainTab.inbox.systemImage) }
                .badge(model.counts["inbox"] ?? 0)
                .tag(MainTab.inbox)
            MailListScreen(tab: .scheduled)
                .tabItem { Label(MainTab.scheduled.title, systemImage: MainTab.scheduled.systemImage) }
                .tag(MainTab.scheduled)
            MailListScreen(tab: .needReply)
                .tabItem { Label(MainTab.needReply.title, systemImage: MainTab.needReply.systemImage) }
                .badge(model.needReplyCount)
                .tag(MainTab.needReply)
            SearchScreen()
                .tabItem { Label(MainTab.search.title, systemImage: MainTab.search.systemImage) }
                .tag(MainTab.search)
        }
            .sheet(isPresented: $model.showAccounts) { AccountsSheet() }
            .sheet(isPresented: $model.showSettings) { SettingsView() }
            .sheet(item: $model.pendingRemind) { row in RemindSheet(row: row) }
            .sheet(item: $model.composeDraft) { draft in ComposeView(draft: draft) }
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
    var id: String { "\(replyToThreadId ?? "new")-\(subject)" }
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
            .background(Theme.card, in: Capsule())
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.bottom, 60) // clears the tab bar
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: toast.id) {
                try? await Task.sleep(for: .seconds(5))
                if model.toast?.id == toast.id { withAnimation { model.toast = nil } }
            }
        }
    }
}
