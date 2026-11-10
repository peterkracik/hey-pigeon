// Settings: the desktop's sections, same order, same wording — Accounts
// (name, colour, sync, signature, reconnect, remove), AI (the provider
// select box — Apple Intelligence, ChatGPT, Claude, Gemini — its key and
// model, auto-summarize), Siri & Search, Default email app (the iOS-only
// doors to the system's Default Apps and Siri & Search pages), Triage (the
// classifier select box, with Jev too, auto-triage, reanalyze, the labels), Inbox (pinned list, swipe
// actions — the desktop's hover actions), About. Account removal and
// anything that deletes asks once. Same sheet look as the sidebar (Theme's
// menuList / menuCard / menuSheet).

import AppIntents
import SwiftUI

/// A page pushed from Settings' root.
enum SettingsRoute: Hashable {
    /// The provider, its key and model, what to do when it cannot answer.
    case ai
    /// The classifier, auto-triage and the triage labels.
    case triage
    /// "Triage my inbox": the run, its rules and the journal.
    case siriTriage

    /// The page's name: its navigation title, and the Mac window's.
    var title: String {
        switch self {
        case .ai: "AI"
        case .triage: "Triage"
        case .siriTriage: "Siri triage"
        }
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The pages pushed over the root, when the host keeps them: the
    /// Mac's window does (`WindowState.settingsPath`), so its own Back,
    /// Esc and title follow a pushed page. The phone's sheet keeps its
    /// own (`ownPath`).
    private let hostPath: Binding<[SettingsRoute]>?
    @State private var ownPath: [SettingsRoute] = []
    private var path: Binding<[SettingsRoute]> { hostPath ?? $ownPath }
    @State private var removing: MailAccount?
    /// The crash and hang reports on this device, read as Settings opens
    /// (DiagnosticsSection shows nothing when there are none).
    @State private var diagnosticReports: [DiagnosticsCollector.Report] = []
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue
    #if os(macOS)
    /// The menu bar extra (macos-app HeyPigeonMacApp reads the same key).
    /// Without a switch here, an icon dragged out of the menu bar had no
    /// way back.
    @AppStorage("menuBarExtra") private var menuBarExtra = true
    #endif

    init(path: Binding<[SettingsRoute]>? = nil) {
        hostPath = path
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: path) {
            SettingsList {
                accountsSection
                // AI and Triage are a page each, on the phone and on the
                // Mac. On one scroll their pickers, keys and privacy
                // footers stood between the top and everything else.
                Section {
                    NavigationLink(value: SettingsRoute.ai) {
                        pageLabel("AI", "Who summarizes, drafts and edits", systemImage: "sparkles")
                    }
                    NavigationLink(value: SettingsRoute.triage) {
                        pageLabel("Triage", "Sorting new mail into your labels", systemImage: "tray.2")
                    }
                }
                .menuCard()
                SiriSection()
                DefaultAppSection()
                NotificationsSection()
                ComposeSection()
                #if os(macOS)
                UpdatesSection()
                #endif
                Section {
                    Toggle(isOn: $model.pinListEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pinned list")
                            Text("Group pinned messages at the top of your inbox, above the rest.")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    // The Mac lists every thread with its chip; only the
                    // phone and the iPad fold.
                    if AppModel.foldsOnThisPlatform {
                        Toggle(isOn: $model.foldBundlesEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Fold bundle updates")
                                Text("Read confirmations, receipts and shipping updates in a bundle share one row in your inbox. Mail that needs you keeps its own row.")
                                    .font(.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                    }
                    Toggle(isOn: $model.loadRemoteImages) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Load remote images")
                            // Privacy copy: what loading a picture from the web tells the sender.
                            Text("Show pictures from the web in every message without asking. The sender's server can then see that you opened the message, when, and your IP address.")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    if !model.imageSenders.isEmpty && !model.loadRemoteImages {
                        HStack {
                            Text(model.imageSenders.count == 1 ? "Images always load from 1 sender"
                                 : "Images always load from \(model.imageSenders.count) senders")
                            Spacer()
                            Button("Forget") { model.imageSenders = [] }
                        }
                    }
                    swipePicker(Self.swipeTitles[0], 0)
                    swipePicker(Self.swipeTitles[1], 1)
                    swipePicker(Self.swipeTitles[2], 2)
                    swipePicker(Self.swipeTitles[3], 3)
                } header: {
                    Text("Inbox")
                } footer: {
                    Text(Self.swipeFooter)
                }
                .menuCard()
                OutboxSection()
                RulesSection()
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in Text(a.title).tag(a.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    menuBarToggle
                }
                .menuCard()
                DiagnosticsSection(reports: $diagnosticReports)
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    Link("heypigeon.app", destination: URL(string: "https://heypigeon.app")!)
                    Link("Privacy", destination: URL(string: "https://heypigeon.app/privacy.html")!)
                } header: {
                    Text("About")
                } footer: {
                    Text(Self.aboutFooter)
                }
                .menuCard()
            }
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            // The pages, by route. On the Mac their Back is the window's
            // (`backInWindowToolbar`): the stack's sat beside the traffic
            // lights, as a thread's did.
            .navigationDestination(for: SettingsRoute.self) { route in
                page(route).backInWindowToolbar()
            }
            // The "not sent" line over the list opens Settings here.
            .navigationDestination(isPresented: $model.showOutbox) { OutboxView() }
            .onAppear { diagnosticReports = DiagnosticsCollector.reports() }
            .sheetCloseButton { Keyboard.dismiss(); dismiss() }
            .dismissKeyboardOnScroll(.interactively)
            .confirmationDialog("Remove \(removing?.email ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                Button("Remove account", role: .destructive) {
                    if let a = removing { Task { await model.removeAccount(a) } }
                    removing = nil
                }
            } message: {
                Text("Removes the local copy of its mail and signs it out on this device. Nothing changes in Gmail.")
            }
        }
        .menuSheet()
        // Closed while on the Outbox page: the next visit starts at the top.
        .onDisappear { model.showOutbox = false }
    }

    /// Appearance › "Show in the menu bar", on the Mac; nothing on the
    /// phone. Its own builder so the `#if` does not sit behind the
    /// picker's modifier.
    @ViewBuilder private var menuBarToggle: some View {
        #if os(macOS)
        Toggle(isOn: $menuBarExtra) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Show in the menu bar")
                Text("The unread count in the menu bar, with what is due and what needs a reply a click away.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
        }
        #endif
    }

    @ViewBuilder private func page(_ route: SettingsRoute) -> some View {
        switch route {
        case .ai: SettingsPage(title: route.title) { AISection() }
        case .triage: SettingsPage(title: route.title) { TriageSection() }
        case .siriTriage: TriageJournalView()
        }
    }

    /// A row that opens one of Settings' pages: its name and, under it,
    /// what is in there.
    private func pageLabel(_ title: String, _ detail: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(Theme.textTertiary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }

    // MARK: Accounts

    private var accountsSection: some View {
        Section {
            ForEach(model.accounts) { a in
                AccountRow(account: a, state: model.accountStates[a.id], onRemove: { removing = a })
            }
            Button { Task { await model.addAccount() } } label: { Label("Add account", systemImage: "plus.circle") }
        } header: {
            Text("Accounts")
        } footer: {
            Text("Connected mailboxes shown in the sidebar.")
        }
        .menuCard()
    }

    private func swipePicker(_ title: String, _ index: Int) -> some View {
        Picker(title, selection: Binding(
            get: { model.swipeActions[index] },
            set: { model.swipeActions[index] = $0 }
        )) {
            ForEach(RowAction.allCases) { a in Label(a.title, systemImage: a.systemImage).tag(a) }
        }
    }

    /// The four tiers, in the words of the gesture each platform has: the
    /// phone's two-distance swipe, the Mac's trackpad swipe and hover bar.
    /// Same synced pref (`swipe_actions`) on both.
    static let swipeTitles: [String] = {
        #if os(macOS)
        ["Swipe right, first", "Swipe right, second", "Swipe left, first", "Swipe left, second"]
        #else
        ["Swipe right, short", "Swipe right, long", "Swipe left, short", "Swipe left, long"]
        #endif
    }()

    static let swipeFooter: String = {
        #if os(macOS)
        "Control how messages are grouped and which actions a two-finger swipe on a row reveals (a full swipe runs the first). The same actions sit in the bar that appears when you hover a row, and on the keys shown under ⌘/."
        #else
        "Control how messages are grouped and what each swipe does. A short swipe arms the first action, a longer one the second."
        #endif
    }()

    static let aboutFooter: String = {
        #if os(macOS)
        "No server, no analytics. Your mail stays between this Mac and your Google account. Updates arrive as new builds on GitHub."
        #else
        "No server, no analytics. Your mail stays between your device and your Google account. Updates arrive through TestFlight and the App Store."
        #endif
    }()
}

/// A page pushed from Settings' root (AI, Triage): the same list look,
/// the page's name in the bar.
private struct SettingsPage<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        SettingsList { content() }
            .navigationTitle(title)
            .toolbarTitleDisplayMode(.inline)
            .dismissKeyboardOnScroll(.interactively)
    }
}

/// One account block: avatar, name/email, status, Reconnect/Remove, then
/// the sub-settings (name, colour, sync, signature).
private struct AccountRow: View {
    let account: MailAccount
    let state: AccountState?
    let onRemove: () -> Void
    @Environment(AppModel.self) private var model
    @State private var name: String
    @State private var signature: String
    @State private var expanded = false

    init(account: MailAccount, state: AccountState?, onRemove: @escaping () -> Void) {
        self.account = account
        self.state = state
        self.onRemove = onRemove
        _name = State(initialValue: account.displayName)
        _signature = State(initialValue: account.signature)
    }

    private var disconnected: Bool { state?.isConnected == false }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LabeledContent("Name") {
                TextField("Name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .onSubmit { saveName() }
                    // Saved once typing pauses, like the signature: it was
                    // saved on Return only, and a name typed and left by
                    // closing Settings was lost.
                    .task(id: name) {
                        try? await Task.sleep(for: AppModel.prefSaveDelay)
                        guard !Task.isCancelled else { return }
                        saveName()
                    }
                    .onDisappear { saveName() }
            }
            LabeledContent("Color") {
                HStack(spacing: 10) {
                    ForEach(AccountColor.allCases, id: \.self) { c in
                        Button { model.updateAccount(account, color: c) } label: {
                            Circle().fill(Theme.tagForeground(c)).frame(width: 22, height: 22)
                                .overlay { if c == account.color { Circle().stroke(Theme.textPrimary, lineWidth: 2).padding(-3) } }
                                .tapArea(horizontal: 5, vertical: 11)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.rawValue)
                        .accessibilityAddTraits(c == account.color ? .isSelected : [])
                    }
                }
            }
            LabeledContent("Sync") {
                Text(syncLine).font(.footnote).foregroundStyle(syncWarn ? Theme.dangerText : Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Signature")
                TextEditor(text: $signature)
                    .frame(minHeight: 60)
                    .font(.subheadline)
                    // Saved once typing pauses: every save is a synced write
                    // plus a reload of every account (it used to be one per
                    // keystroke). Closing Settings saves what is left.
                    .task(id: signature) {
                        try? await Task.sleep(for: AppModel.prefSaveDelay)
                        guard !Task.isCancelled else { return }
                        saveSignature()
                    }
                    .onDisappear { saveSignature() }
                Text("Appended to new messages from this account").font(.caption).foregroundStyle(Theme.textTertiary)
            }
            if disconnected {
                Button { Task { await model.addAccount(loginHint: account.id) } } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            }
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
        } label: {
            HStack(spacing: 12) {
                Avatar(account: account)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.displayName).font(.body.weight(.medium))
                    Text(account.email).font(.caption).foregroundStyle(Theme.textTertiary)
                    if disconnected {
                        Text("Disconnected — mail stops syncing until you sign in again").font(.caption).foregroundStyle(Theme.dangerText)
                    }
                }
            }
        }
        // Renamed or re-signed on another device while this row is open.
        .onChange(of: account.displayName) { _, v in name = v }
        .onChange(of: account.signature) { _, v in if v != signature { signature = v } }
    }

    /// An emptied field is not a name to save.
    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, trimmed != account.displayName { model.updateAccount(account, displayName: trimmed) }
    }

    private func saveSignature() {
        if signature != account.signature { model.updateAccount(account, signature: signature) }
    }

    private var syncLine: String {
        guard let s = state else { return "Waiting for first sync" }
        let last = s.lastSyncAt.map { " · Last sync: \(Formatters.rowTime($0))" } ?? ""
        switch s.syncState {
        case "pending": return "Syncing…"
        case "ok": return "On\(last)"
        case "auth_expired": return "Sign in again to sync reminders and settings"
        default: return (s.syncDetail ?? "Sync failed") + last
        }
    }

    private var syncWarn: Bool {
        guard let s = state else { return false }
        return !["pending", "ok"].contains(s.syncState)
    }
}

/// Initials in the account's tag colours; the Google photo when there is one.
struct Avatar: View {
    let account: MailAccount
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            Circle().fill(Theme.tagBackground(account.color))
            Text(String(account.displayName.prefix(1)).uppercased())
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Theme.tagForeground(account.color))
            if let url = account.avatarURL {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Color.clear }
                    .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - AI

/// One "Provider" select box: Apple Intelligence on this device, Apple's
/// cloud, ChatGPT, Claude or Gemini (the last three with an API key the
/// user pastes — tokens only, no account sign-in). Under it, the picked
/// provider's state: availability for Apple's models, the key and the
/// model for a keyed one. "If it can't answer" orders the rest. Under the
/// card, what each provider has cost in tokens since the last reset.
private struct AISection: View {
    @Environment(AppModel.self) private var model
    @State private var status: AIStatus?
    @State private var providers: [AIProviderInfo] = []
    @State private var error: String?
    private let usage = AiUsageLedger.shared

    private var preferred: AIProvider { AIProvider(rawValue: status?.preferredProviderId ?? "openai") }
    private var anyApple: Bool { providers.contains { $0.available } }
    /// Everything the select box offers: the shell's providers (both Apple
    /// models, available or not, and registered packages), the keyed three,
    /// and the one preferred on another device even if this one lacks it
    /// (so the picker never shows a blank).
    private var choices: [AIProvider] {
        var out = providers.map { AIProvider(rawValue: $0.id) }
        for p in AIProvider.keyed where !out.contains(p) { out.append(p) }
        if !out.contains(preferred) { out.append(preferred) }
        return out
    }

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Provider", selection: Binding(get: { preferred }, set: { setProvider($0) })) {
                ForEach(choices) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.menu)
            if preferred.takesKey {
                KeyedProviderControls(provider: preferred, hasKey: status?.hasKey(preferred) == true,
                                      answering: status?.providerId == preferred.rawValue) {
                    load()
                    model.reloadAccounts()
                }
            } else {
                HStack(spacing: 12) {
                    mark(preferred == .appleCloud ? "PCC" : "AI")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(preferred.title).font(.body.weight(.medium))
                        Text(shellLine(preferred)).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
            }
            if let active = status?.providerId, active != preferred.rawValue {
                Text("Answering now: \(AIProvider(rawValue: active).title)")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            } else if status?.configured == false {
                Text("Nothing can answer yet: pick a provider this \(Device.name) can run, or paste a key.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            Picker("If it can't answer", selection: Binding(
                get: { AIFallbackPreset(order: status?.fallbackOrder ?? []) },
                set: { setFallback($0) }
            )) {
                ForEach(AIFallbackPreset.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.menu)
            if status?.configured == true {
                Toggle("Auto-summarize", isOn: $model.autoSummarize)
            }
            if anyApple {
                Toggle(isOn: $model.suggestEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggest for new mail")
                        Text("Need reply, or Remind me on the date an email names")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Toggle(isOn: $model.autoBundlesEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Make bundles")
                        Text("Group new mail about a trip, an order or a project")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.dangerText) }
        } header: {
            Text("AI")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Pick who summarizes, drafts and edits. Apple Intelligence on this \(Device.name) runs with nothing leaving the device and no key. Apple's cloud (Private Cloud Compute) is Apple's own larger model: your request goes to Apple's servers, is never stored, and needs no key either. ChatGPT, Claude and Gemini each take an API key you paste — no account sign-in — and email content goes to that provider only on an explicit AI action: drafting and editing always run on your tap; summaries run on your tap too, unless you turn on auto-summarize. Keys stay on this device (paste them on each one); the provider, the models and the fallback order follow you to your other devices.")
                if anyApple && model.suggestEnabled {
                    // Privacy copy must be true (CLAUDE.md): this is the one
                    // AI path that reads a body without a tap.
                    Text("Suggest for new mail: each new unread email (up to \(Self.suggestChars.formatted()) characters of its text) is read by Apple Intelligence — on this \(Device.name) or in Apple's cloud, never ChatGPT, Claude or Gemini — to propose Need reply or a reminder. Nothing changes until you accept.")
                }
                if anyApple && model.autoBundlesEnabled {
                    // Privacy copy must be true (CLAUDE.md): what the
                    // bundling pass sends (crates/ffi/src/bundles.rs).
                    Text("Make bundles: the sender, subject and preview line of each new email, with the names of your bundles, go to Apple Intelligence — never ChatGPT, Claude or Gemini. Bundles it makes stay on this \(Device.name) until you edit one.")
                }
                usageLines
            }
        }
        .menuCard()
        .task { load() }
        .onChange(of: model.prefsVersion) { _, _ in load() }
    }

    /// What the core sends of a new email's text (SUGGEST_BODY_CHARS in
    /// crates/ffi/src/suggest.rs).
    static let suggestChars = 4_000

    /// The line under a shell provider: answering · available · why not.
    private func shellLine(_ p: AIProvider) -> String {
        guard let info = providers.first(where: { $0.id == p.rawValue }) else {
            return "Not available on this \(Device.name)"
        }
        if status?.providerId == info.id { return "\(info.modelLabel) · answering" }
        if info.available { return info.leavesDevice ? "\(info.modelLabel) · available · Apple-private, never stored" : "\(info.modelLabel) · available" }
        return info.unavailableReason ?? "Not available"
    }

    /// Tokens per provider since the last reset (iOS 27 `response.usage`),
    /// and a Reset when there is anything to reset.
    @ViewBuilder private var usageLines: some View {
        let used = usage.byProvider.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
        if !used.isEmpty {
            ForEach(used, id: \.key) { id, u in
                Text("\(AIProvider(rawValue: id).title): \(AiUsageLedger.line(u, price: AiUsageLedger.prices[id]))")
                    .font(.caption2.monospacedDigit())
            }
            Button("Reset usage") { usage.reset() }.font(.caption2.weight(.semibold))
        }
    }

    private func load() {
        model.engine.refreshAIProviders()
        status = try? model.engine.aiStatus()
        providers = model.engine.aiProviders()
    }

    private func setProvider(_ p: AIProvider) {
        do { try model.engine.setAIProvider(p) } catch { self.error = error.localizedDescription }
        load()
        model.reloadAccounts()
    }

    private func setFallback(_ f: AIFallbackPreset) {
        do { try model.engine.setAIFallback(f.order) } catch { self.error = error.localizedDescription }
        load()
        model.reloadAccounts()
    }
}

/// One keyed provider (ChatGPT, Claude, Gemini): connected or a field to
/// paste its API key, Remove, and the model picker. Settings › AI and
/// Settings › Triage both show it — a provider has one key on this device,
/// whichever section it was pasted in.
private struct KeyedProviderControls: View {
    @Environment(AppModel.self) private var model
    let provider: AIProvider
    let hasKey: Bool
    var answering = false
    /// Called after a key or model change, so the section re-reads.
    let onChange: () -> Void
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var models: [AIModel] = []
    @State private var selected: String?

    /// Spelled out: the private state would make the memberwise one private.
    init(provider: AIProvider, hasKey: Bool, answering: Bool = false, onChange: @escaping () -> Void) {
        self.provider = provider
        self.hasKey = hasKey
        self.answering = answering
        self.onChange = onChange
    }

    var body: some View {
        Group {
            HStack(spacing: 12) {
                mark(provider.mark)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.title).font(.body.weight(.medium))
                    Text(statusLine).font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if hasKey {
                    // Asks once, in the dialog an account's Remove uses (a
                    // key is not kept anywhere to bring back): it was a
                    // second tap on a button that had changed its words.
                    Button("Remove") { confirmRemove = true }
                        .font(.footnote.weight(.semibold))
                        .confirmationDialog("Remove the \(provider.shortName) key?", isPresented: $confirmRemove,
                                            titleVisibility: .visible) {
                            Button("Remove key", role: .destructive) { remove() }
                        } message: {
                            Text("The key is deleted from this \(Device.name). \(provider.shortName) answers here again once you paste one.")
                        }
                }
            }
            if hasKey {
                Picker("Model", selection: Binding(
                    get: { selected ?? models.first?.id ?? "" },
                    set: { select($0) }
                )) {
                    ForEach(models) { m in Text(m.label).tag(m.id) }
                }
                .pickerStyle(.menu)
            } else {
                HStack {
                    SecureField(provider.keyPlaceholder, text: $key)
                        .plainInput()
                        .onSubmit { connect() }
                    Button(saving ? "Verifying…" : "Connect") { connect() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .font(.footnote.weight(.semibold))
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.dangerText) }
        }
        .task(id: provider) { load() }
        .onChange(of: model.prefsVersion) { _, _ in load() }
    }

    private var modelLabel: String {
        models.first { $0.id == selected }?.label ?? selected ?? models.first?.label ?? ""
    }

    private var statusLine: String {
        guard hasKey else { return "Not connected · paste your \(provider.shortName) API key" }
        return answering ? "Connected · \(modelLabel) · answering" : "Connected · \(modelLabel)"
    }

    private func load() {
        models = (try? model.engine.aiModels(for: provider)) ?? []
        selected = (try? model.engine.aiSelectedModel(for: provider)) ?? nil
        confirmRemove = false
    }

    private func connect() {
        saving = true
        error = nil
        Task {
            do {
                try await model.engine.setAIKey(key, for: provider)
                key = ""
                load()
                onChange()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    private func remove() {
        confirmRemove = false
        do { try model.engine.removeAIKey(for: provider) } catch { self.error = error.localizedDescription }
        onChange()
    }

    private func select(_ id: String) {
        do { try model.engine.setAIModel(id, for: provider) } catch { self.error = error.localizedDescription }
        load()
        onChange()
    }
}

private extension AIProvider {
    /// The two or three letters on the provider's row.
    var mark: String {
        switch self {
        case .apple: "AI"
        case .appleCloud: "PCC"
        case .openai: "GPT"
        case .anthropic: "C"
        case .gemini: "G"
        case .other(let id): String(id.prefix(2)).uppercased()
        }
    }
}

/// The fallback orders Settings offers (`pref:ai.fallback`), by how much
/// may leave the device when the preferred provider cannot answer.
enum AIFallbackPreset: CaseIterable, Identifiable, Hashable {
    /// On this iPhone → Apple's cloud → a keyed provider (the engine's default).
    case privateFirst
    /// Apple's cloud → on this iPhone → a keyed provider: the big window first.
    case cloudFirst
    /// On this iPhone only: never a network hop the user did not pick.
    case onDeviceOnly

    var id: Self { self }

    var order: [AIProvider] {
        switch self {
        case .privateFirst: []  // empty = the engine's default
        case .cloudFirst: [.appleCloud, .apple] + AIProvider.keyed
        case .onDeviceOnly: [.apple]
        }
    }

    var title: String {
        switch self {
        case .privateFirst: "On this \(Device.name), then Apple's cloud, then a provider with a key"
        case .cloudFirst: "Apple's cloud, then on this \(Device.name), then a provider with a key"
        case .onDeviceOnly: "Stay on this \(Device.name)"
        }
    }

    /// An order that starts in Apple's cloud reads as cloud-first, the
    /// three-entry one an older build synced included.
    init(order: [String]) {
        if order == ["apple"] {
            self = .onDeviceOnly
        } else if order.count > 1, order.first == AIProvider.appleCloud.rawValue {
            self = .cloudFirst
        } else {
            self = .privateFirst
        }
    }
}

// MARK: - Siri & Search

/// The Spotlight index Siri's personal context and Spotlight read, and a
/// door to the app's Siri phrases. What leaves the device is stated plainly.
private struct SiriSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle(isOn: $model.siriIndexEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Siri see your inbox")
                    Text("Recent mail indexed on this \(Device.name) — subject, sender, people, labels, and the text of messages you have opened — so Siri and Spotlight can find a thread and \"Ask my inbox\" can answer from it. The index never leaves the device.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            if InboxAsk.isAvailable(model) {
                Button { model.askFromSettings() } label: {
                    Label("Ask my inbox", systemImage: "questionmark.bubble")
                }
            }
            #if os(iOS)
            // The Mac has neither the Siri tip nor ShortcutsLink: Siri
            // offers the phrases itself and the Shortcuts app lists the
            // actions on its own.
            SiriTipView(intent: WhatNeedsReplyIntent())
            ShortcutsLink()
            #endif
            Button { SystemSettings.openAppSettings() } label: {
                Label(Self.systemButtonTitle, systemImage: "gear")
            }
        } header: {
            Text("Siri & Search")
        } footer: {
            Text(Self.footer)
        }
        .menuCard()
    }

    static let systemButtonTitle: String = {
        #if os(macOS)
        "Apple Intelligence & Siri settings"
        #else
        "Siri & Search for Hey Pigeon"
        #endif
    }()

    static let footer: String = {
        #if os(macOS)
        "Ask Siri what needs a reply or what's due, ask your inbox a question, or add any action to a Shortcut. Nothing is sent anywhere: Siri and the on-device model read the index on this Mac.\n\nTo have Siri and Spotlight answer from Hey Pigeon's mail rather than Apple Mail's: keep the switch above on, and in System Settings › Apple Intelligence & Siri › Apps keep Hey Pigeon's Siri access on while turning off \"Learn from this App\" for Mail; Spotlight › Search Results decides which apps' mail Spotlight lists."
        #else
        "Ask Siri what needs a reply or what's due, say \"remind me about this tomorrow\" on an open thread, ask your inbox a question, or add any action to a Shortcut. Nothing is sent anywhere: Siri and the on-device model read the index on this \(Device.name).\n\nTo have Siri and Spotlight answer from Hey Pigeon's mail rather than Apple Mail's: keep the switch above on, make sure \"Show in Search\" and \"Learn from this App\" are on for Hey Pigeon in iOS Settings, and turn the same two off for Mail (iOS Settings › Apps › Mail › Siri & Search)."
        #endif
    }()
}

// MARK: - Default mail app

/// The door to iOS Settings › Apps › Default Apps, where Hey Pigeon is
/// offered as the Email app once the build carries the default-mail-client
/// entitlement (project.yml). iOS cannot tell the app which app is the
/// default, so there it is a button and a sentence. The Mac can: the app
/// asks the system to make it the mailto: handler (macOS confirms once)
/// and shows whether it is.
private struct DefaultAppSection: View {
    /// Re-read after the button, which changes it.
    @State private var isDefault = false

    var body: some View {
        Section {
            #if os(macOS)
            if isDefault {
                Label("Hey Pigeon is the default email app", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Button { SystemSettings.openDefaultApps(); refresh() } label: {
                    Label("Make Hey Pigeon the default email app", systemImage: "envelope.badge.person.crop")
                }
            }
            #else
            Button { SystemSettings.openDefaultApps() } label: {
                Label("Set Hey Pigeon as the default email app", systemImage: "envelope.badge.person.crop")
            }
            #endif
        } header: {
            Text("Default email app")
        } footer: {
            Text(Self.footer)
        }
        .menuCard()
        .onAppear { refresh() }
    }

    private func refresh() {
        #if os(macOS)
        // The system's confirmation dialog answers a moment later.
        Task {
            try? await Task.sleep(for: .seconds(1))
            isDefault = SystemSettings.isDefaultMailApp
        }
        isDefault = SystemSettings.isDefaultMailApp
        #endif
    }

    static let footer: String = {
        #if os(macOS)
        "macOS asks you to confirm once. Every mail link you click afterwards — in Safari, Notes, a contact card, another app — opens a new message here, and \"send an email\" asked of Siri composes here too. Nothing is sent until you click Send."
        #else
        "Opens iOS Settings › Apps › Default Apps. Pick Hey Pigeon under Email and every mail link you tap — in Safari, Notes, a contact card, another app — opens a new message here, and \"send an email\" asked of Siri composes here too. Nothing is sent until you tap Send."
        #endif
    }()
}

// MARK: - Triage

/// A "Classifier" select box — Apple Intelligence on this device or in
/// Apple's cloud, ChatGPT, Claude, Gemini (the same key as Settings › AI),
/// or Jev — and under it the picked one's state, then auto-triage, Siri
/// triage and the labels.
private struct TriageSection: View {
    @Environment(AppModel.self) private var model
    @State private var status: TriageStatus?
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var newLabel = ""
    /// The triage label the Remove dialog is asking about.
    @State private var removing: TriageLabelItem?
    @State private var reanalyzeQueued = false

    private var jevConfigured: Bool { status?.jevConfigured == true }
    private var onDevice: Bool { status?.onDeviceAvailable == true }
    private var current: TriageClassifier { TriageClassifier(rawValue: status?.classifierId ?? "") ?? .apple }

    var body: some View {
        Section {
            Picker("Classifier", selection: Binding(get: { current }, set: { setClassifier($0) })) {
                ForEach(TriageClassifier.allCases) { c in Text(c.title).tag(c) }
            }
            .pickerStyle(.menu)
            switch current {
            case .apple, .appleCloud:
                HStack(spacing: 12) {
                    mark(current == .appleCloud ? "PCC" : "AI")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title).font(.body.weight(.medium))
                        Text(appleLine).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
            case .openai, .anthropic, .gemini:
                if let provider = current.aiProvider {
                    KeyedProviderControls(provider: provider, hasKey: status?.isAvailable(current) == true) { load() }
                }
            case .jev:
                HStack(spacing: 12) {
                    mark("TS")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Jev").font(.body.weight(.medium))
                        Text(jevConfigured ? "Connected" : "Not connected")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    if jevConfigured {
                        Button("Remove") { confirmRemove = true }
                            .font(.footnote.weight(.semibold))
                            .confirmationDialog("Remove the Jev key?", isPresented: $confirmRemove, titleVisibility: .visible) {
                                Button("Remove key", role: .destructive) { remove() }
                            } message: {
                                Text("The key is deleted from this \(Device.name). Jev classifies here again once you paste one.")
                            }
                    }
                }
                if !jevConfigured {
                    HStack {
                        SecureField("API key", text: $key)
                            .plainInput()
                            .onSubmit { connect() }
                        Button(saving ? "Verifying…" : "Connect") { connect() }
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
            if status?.configured == true && status?.isAvailable(current) != true {
                Text("\(current.title) can't run here yet, so Apple Intelligence or Jev classifies instead.")
                    .font(.caption).foregroundStyle(Theme.textTertiary)
            }
            if status?.configured == true {
                Toggle("Auto-triage", isOn: Binding(get: { status?.enabled ?? false }, set: { setEnabled($0) }))
                HStack {
                    Button("Reanalyze all emails") {
                        do { try model.reanalyzeAllEmails(); reanalyzeQueued = true } catch { self.error = error.localizedDescription }
                    }
                    .font(.footnote.weight(.semibold))
                    .disabled(model.analysis.isActive)
                    if reanalyzeQueued && !model.analysis.isActive && status?.enabled != true {
                        Text("Queued — runs once Auto-triage is on.").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                if model.analysis.isActive {
                    AnalysisProgressRow(progress: model.analysis)
                }
                if let last = status?.lastError {
                    Text("Last run failed: \(last)").font(.footnote).foregroundStyle(Theme.dangerText)
                }
            }
            // "Hey Siri, triage my inbox": the agentic run over the engine
            // (AI/TriageAgent.swift). Its dry-run switch, the user's own
            // rules and the journal of what it did are one page
            // (TriageJournalView).
            if onDevice {
                NavigationLink(value: SettingsRoute.siriTriage) {
                    Label(model.triageAgent.map { "Siri triage · \($0.phase.title)" } ?? "Siri triage and journal",
                          systemImage: "list.bullet.rectangle")
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(Theme.dangerText) }
        } header: {
            Text("Triage")
        } footer: {
            // Privacy copy must be true (CLAUDE.md): what each classifier
            // is sent (settings.rs classify_pending_inner, keyed.rs).
            Text(Self.footer)
        }
        .menuCard()
        .task { load() }
        .onChange(of: model.prefsVersion) { _, _ in load() }
        // The labels: the categories the classifier sorts mail into, and the
        // segments of the bottom pill, in this order (drag to change it).
        // A section of their own: they sat unnamed between the switches.
        Section {
            ForEach(model.triageLabels) { l in
                Text(l.name)
                    // Asks first: a label made again is a new label, so
                    // there is no Undo to offer. The menu is the way on
                    // the Mac, whose form has no swipe.
                    .swipeActions {
                        Button(role: .destructive) { removing = l } label: { Label("Remove", systemImage: "trash") }
                    }
                    .contextMenu {
                        Button(role: .destructive) { removing = l } label: { Label("Remove…", systemImage: "trash") }
                    }
            }
            .onMove { model.moveTriageLabels(from: $0, to: $1) }
            if model.triageLabels.isEmpty {
                Text("No labels yet").font(.footnote).foregroundStyle(Theme.textTertiary)
            }
            HStack {
                TextField("New label name", text: $newLabel).onSubmit { add() }
                Button("Add") { add() }
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    .font(.footnote.weight(.semibold))
            }
            // On this one row, not on the labels: a modifier on the
            // ForEach goes to every row, and each would present it.
            .confirmationDialog("Remove “\(removing?.name ?? "")”?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { l in
                Button("Remove label", role: .destructive) { delete(l) }
            } message: { _ in
                Text("It leaves the bar over your inbox, on every device.")
            }
        } header: {
            Text("Labels")
        } footer: {
            Text("What mail is sorted into, and the bar over your inbox, in this order. \(Self.labelHint)")
        }
        .menuCard()
    }

    /// What each classifier is sent, and what syncs.
    private static var footer: String {
        "New mail is sorted into your own labels and given a priority in the background, from the subject, sender and preview (never the full message). Apple Intelligence on this \(Device.name) does it with nothing leaving the device; Apple's cloud sends those three fields to Apple, never stored. Pick ChatGPT, Claude or Gemini and they go to that provider with your API key (the same key as in AI). Jev is a third-party classification service, not part of Hey Pigeon — see jevtypesafeai.com. When the classifier you pick can't run, Apple Intelligence or Jev takes over — never a provider you didn't pick. Keys stay on this device; your labels, the switch and the classifier choice sync to your other devices."
    }

    private func load() { status = try? model.engine.triageStatus() }

    /// The line under an Apple classifier: available, or why not.
    private var appleLine: String {
        if status?.isAvailable(current) == true {
            return current == .appleCloud
                ? "Private Cloud Compute · deeper reasoning on the same subject, sender and preview; Apple-private, never stored"
                : "Sorts and prioritizes with nothing leaving the device"
        }
        let info = model.engine.aiProviders().first { $0.id == current.rawValue }
        return info?.unavailableReason ?? "Not available on this \(Device.name)"
    }

    /// How to reorder and remove a label, in this platform's gestures.
    #if os(macOS)
    private static let labelHint = "Drag a label to change the order the bar shows; right-click it to remove it."
    #else
    private static let labelHint = "Touch and hold a label, then drag it to change the order the bar shows; swipe it left to remove it."
    #endif

    private func connect() {
        saving = true
        error = nil
        Task {
            do {
                try await model.engine.setJevKey(key)
                key = ""
                load()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    private func remove() {
        confirmRemove = false
        do { try model.engine.removeJevKey() } catch { self.error = error.localizedDescription }
        load()
    }

    private func setEnabled(_ on: Bool) {
        do { try model.engine.setAutoTriage(on) } catch { self.error = error.localizedDescription }
        load()
    }

    private func setClassifier(_ c: TriageClassifier) {
        do { try model.engine.setTriageClassifier(c) } catch { self.error = error.localizedDescription }
        load()
    }

    private func add() {
        let name = newLabel.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        do {
            _ = try model.engine.createTriageLabel(name: name)
            newLabel = ""
            model.reloadAccounts()
        } catch { self.error = error.localizedDescription }
    }

    private func delete(_ l: TriageLabelItem) {
        do {
            try model.engine.deleteTriageLabel(id: l.id)
            model.reloadAccounts()
            model.reload()
        } catch { self.error = error.localizedDescription }
    }
}

#if os(macOS)
// MARK: Updates (the Mac's Sparkle feed — macos-app/README.md)

/// The Mac updates itself from the builds publish-macos puts on GitHub
/// (MacUpdater, injected by HeyPigeonMacApp's Settings scene); the section
/// only shows in a build that carries the feed and its key.
private struct UpdatesSection: View {
    @Environment(MacUpdater.self) private var updater: MacUpdater?

    var body: some View {
        if let updater, updater.isEnabled {
            UpdatesRows(updater: updater)
        }
    }
}

private struct UpdatesRows: View {
    @Bindable var updater: MacUpdater

    var body: some View {
        Section {
            Toggle(isOn: $updater.installsAutomatically) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Install updates automatically")
                    Text("A new build downloads in the background and installs when you next quit the app. Off, it asks first.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Button("Check for Updates…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        } header: {
            Text("Updates")
        } footer: {
            Text("Once an hour the app asks GitHub for the newest build of Hey Pigeon for Mac and verifies the download's signature. The check carries nothing about your mail.")
        }
        .menuCard()
    }
}
#endif

// MARK: Notifications (the optional push relay — relay/README.md)

private struct NotificationsSection: View {
    @Environment(AppModel.self) private var model
    /// The Mac's new-mail banners come from its own periodic sync, not a
    /// relay: one local switch, on by default (HeyPigeonMacApp reads it).
    @AppStorage("newMailNotifications") private var newMailNotifications = true

    /// The Mac always has its local switch. The phone's only row is the
    /// relay's, so a build without the relay shows no section at all: it
    /// used to show a switch that was off and could not be turned on.
    private static func showsSection(canEnablePush: Bool) -> Bool {
        #if os(macOS)
        true
        #else
        canEnablePush
        #endif
    }

    var body: some View {
        let push = model.push
        if Self.showsSection(canEnablePush: push.canEnable) {
            section(push)
        }
    }

    private func section(_ push: PushController) -> some View {
        Section {
            #if os(macOS)
            Toggle(isOn: $newMailNotifications) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New mail")
                    Text("A banner for each new unread thread the sync brings in while the app is in the background.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            Button { SystemSettings.openNotificationSettings() } label: {
                Label("Notification settings for Hey Pigeon", systemImage: "bell.badge")
            }
            #endif
            if push.canEnable {
                Toggle(isOn: Binding(get: { push.enabled }, set: { on in Task { await push.setEnabled(on) } })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("New mail (push)")
                        Text(statusLine).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .disabled(push.busy)
            }
            if let error = push.lastError { Text(error).font(.footnote).foregroundStyle(Theme.dangerText) }
        } header: {
            Text("Notifications")
        } footer: {
            Text(Self.footer)
        }
        .menuCard()
        .onAppear { push.refreshStatus() }
    }

    static let footer: String = {
        #if os(macOS)
        "The Mac checks for mail every 30 seconds while the app is open (every two minutes in Low Power Mode, and not while it has no network) and composes the banner itself; nothing goes through a relay. A banner's buttons mark the thread done, set a reminder an hour on, or open a reply. Reminders are local notifications either way."
        #else
        "Goes through a small relay that only ever sees your address and a change counter, never mail; the notification text is composed on this phone. Turn it off and the app syncs on open and in the background instead. Reminders stay local either way."
        #endif
    }()

    /// One line under the toggle: state, then the sync lease when there is one.
    private var statusLine: String {
        let push = model.push
        if push.busy { return "Working…" }
        if !push.enabled { return "Off" }
        guard push.status?.enabled == true else {
            return push.deviceToken == nil ? "Registering…" : "On · not registered yet"
        }
        let leases = (push.status?.accounts ?? []).compactMap(\.watchExpiresAt)
        guard let soonest = leases.min() else { return "On · syncing on next open" }
        let n = push.status?.accounts.count ?? 0
        let who = n > 1 ? "\(n) accounts" : "mailbox"
        return "On · \(who) watched until \(soonest.formatted(date: .abbreviated, time: .shortened))"
    }
}

private func mark(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 12, weight: .bold))
        .foregroundStyle(Theme.textSecondary)
        .frame(width: 32, height: 32)
        .background(Theme.sunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
}

// MARK: - Compose

/// Settings › Compose: how long a send waits for Undo, and the snippets
/// the composer's quote button (and the Mac's command palette) insert.
private struct ComposeSection: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Snippet?

    var body: some View {
        @Bindable var model = model
        Section {
            Picker("Undo send", selection: $model.sendUndoSeconds) {
                ForEach(AppModel.sendUndoChoices, id: \.self) { seconds in
                    Text("\(seconds) seconds").tag(seconds)
                }
            }
            ForEach(model.snippets) { snippet in
                Button { editing = snippet } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snippet.name.isEmpty ? "Untitled" : snippet.name).foregroundStyle(Theme.textPrimary)
                            Text(snippet.body).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Button { editing = Snippet(name: "", body: "") } label: { Label("New snippet", systemImage: "plus") }
                // On one row, not on the section: a section hands its
                // modifiers to every row, and each would present the sheet.
                .sheet(item: $editing) { snippet in
                    SnippetEditor(snippet: snippet)
                }
        } header: {
            Text("Compose")
        } footer: {
            Text(Self.footer)
        }
        .menuCard()
    }

    static let footer: String = {
        #if os(macOS)
        "A sent message waits this long before it leaves, with Undo in the toast (and on Z). Snippets are pieces of text you drop into a message from the composer or the command palette; like your other settings they sync to your devices through your own Google Drive."
        #else
        "A sent message waits this long before it leaves, with Undo in the toast. Snippets are pieces of text you drop into a message from the composer; like your other settings they sync to your devices through your own Google Drive."
        #endif
    }()
}

/// One snippet: its name and its text, saved or deleted.
private struct SnippetEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var snippet: Snippet

    private var isNew: Bool { !model.snippets.contains { $0.id == snippet.id } }
    private var canSave: Bool { !snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The title row the other bar-less sheets have (Theme's
            // SheetHeader); its close, and Esc, leave without saving.
            SheetHeader(title: isNew ? "New snippet" : "Snippet") { dismiss() }
            TextField("Name (shown in the menu)", text: $snippet.name)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $snippet.body)
                .font(.body)
                .frame(minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.separator, lineWidth: 1))
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        model.snippets.removeAll { $0.id == snippet.id }
                        dismiss()
                    }
                }
                Spacer()
                Button("Save") { save() }
                    .pillButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .snippetEditorSize()
        .background(Theme.canvas)
    }

    private func save() {
        var s = snippet
        s.name = s.name.trimmingCharacters(in: .whitespaces)
        if s.name.isEmpty {
            // Its first words name it.
            s.name = String(s.body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(32))
        }
        if let index = model.snippets.firstIndex(where: { $0.id == s.id }) {
            model.snippets[index] = s
        } else {
            model.snippets.append(s)
        }
        dismiss()
    }
}

private extension View {
    /// A dialog on the Mac; the phone's sheet is as wide as the screen.
    func snippetEditorSize() -> some View {
        #if os(macOS)
        frame(width: 460)
        #else
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        #endif
    }
}
