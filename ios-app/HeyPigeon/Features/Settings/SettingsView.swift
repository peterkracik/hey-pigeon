// Settings: the desktop's sections, same order, same wording — Accounts
// (name, colour, sync, signature, reconnect, remove), AI (OpenAI key,
// model, auto-summarize), Triage (Jev key, auto-triage, reanalyze, the
// labels), Inbox (pinned list, swipe actions — the desktop's hover actions),
// About. Account removal and anything that deletes asks once. Same sheet
// look as the sidebar (Theme's menuList / menuCard / menuSheet).

import AppIntents
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var removing: MailAccount?
    @AppStorage("appearance") private var appearance = Appearance.system.rawValue

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                accountsSection
                AISection()
                SiriSection()
                TriageSection()
                NotificationsSection()
                Section {
                    Toggle(isOn: $model.pinListEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Pinned list")
                            Text("Group pinned messages at the top of your inbox, above the rest.")
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    swipePicker("Swipe right, short", 0)
                    swipePicker("Swipe right, long", 1)
                    swipePicker("Swipe left, short", 2)
                    swipePicker("Swipe left, long", 3)
                } header: {
                    Text("Inbox")
                } footer: {
                    Text("Control how messages are grouped and what each swipe does. A short swipe arms the first action, a longer one the second.")
                }
                .menuCard()
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { a in Text(a.title).tag(a.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
                .menuCard()
                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                    Link("heypigeon.app", destination: URL(string: "https://heypigeon.app")!)
                    Link("Privacy", destination: URL(string: "https://heypigeon.app/privacy.html")!)
                } header: {
                    Text("About")
                } footer: {
                    Text("No server, no analytics. Your mail stays between your device and your Google account. Updates arrive through TestFlight and the App Store.")
                }
                .menuCard()
            }
            .menuList()
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close) { Keyboard.dismiss(); dismiss() }
                }
            }
            .scrollDismissesKeyboard(.interactively)
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
                    .onSubmit { model.updateAccount(account, displayName: name) }
            }
            LabeledContent("Color") {
                HStack(spacing: 10) {
                    ForEach(AccountColor.allCases, id: \.self) { c in
                        Button { model.updateAccount(account, color: c) } label: {
                            Circle().fill(Theme.tagForeground(c)).frame(width: 22, height: 22)
                                .overlay { if c == account.color { Circle().stroke(Theme.textPrimary, lineWidth: 2).padding(-3) } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(c.rawValue)
                    }
                }
            }
            LabeledContent("Sync") {
                Text(syncLine).font(.footnote).foregroundStyle(syncWarn ? .red : Theme.textSecondary)
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Signature")
                TextEditor(text: $signature)
                    .frame(minHeight: 60)
                    .font(.subheadline)
                    .onChange(of: signature) { _, s in model.updateAccount(account, signature: s) }
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
                        Text("Disconnected — mail stops syncing until you sign in again").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
        // Renamed or re-signed on another device while this row is open.
        .onChange(of: account.displayName) { _, v in name = v }
        .onChange(of: account.signature) { _, v in if v != signature { signature = v } }
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

private struct AISection: View {
    @Environment(AppModel.self) private var model
    @State private var status: AIStatus?
    @State private var models: [AIModel] = []
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false

    var body: some View {
        @Bindable var model = model
        Section {
            HStack(spacing: 12) {
                mark("AI")
                VStack(alignment: .leading, spacing: 2) {
                    Text("ChatGPT (OpenAI)").font(.body.weight(.medium))
                    Text(status?.configured == true ? "Connected · \(modelLabel)" : "Not connected")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if status?.configured == true {
                    Button(confirmRemove ? "Really remove?" : "Remove", role: confirmRemove ? .destructive : nil) {
                        if confirmRemove { remove() } else { confirmRemove = true }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            if status?.configured == true {
                Picker("Model", selection: Binding(
                    get: { status?.model ?? models.first?.id ?? "" },
                    set: { select($0) }
                )) {
                    ForEach(models) { m in Text(m.label).tag(m.id) }
                }
                Toggle("Auto-summarize", isOn: $model.autoSummarize)
            } else {
                HStack {
                    SecureField("sk-…", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { connect() }
                    Button(saving ? "Verifying…" : "Connect") { connect() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .font(.footnote.weight(.semibold))
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("AI")
        } footer: {
            Text("Bring your own API key. Email content is sent to the provider only on an explicit AI action — drafting and editing always run on your tap; summaries run on your tap too, unless you turn on auto-summarize. The key stays on this device (paste it on each one); the model you pick follows you to your other devices.")
        }
        .menuCard()
        .task { load() }
        .onChange(of: model.prefsVersion) { _, _ in load() }
    }

    private var modelLabel: String {
        models.first { $0.id == status?.model }?.label ?? status?.model ?? models.first?.label ?? ""
    }

    private func load() {
        status = try? model.engine.aiStatus()
        models = (try? model.engine.aiModels()) ?? []
    }

    private func connect() {
        saving = true
        error = nil
        Task {
            do {
                try await model.engine.setAIKey(key)
                key = ""
                load()
                model.reloadAccounts()
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    private func remove() {
        confirmRemove = false
        do { try model.engine.removeAIKey() } catch { self.error = error.localizedDescription }
        load()
        model.reloadAccounts()
    }

    private func select(_ id: String) {
        do { try model.engine.setAIModel(id) } catch { self.error = error.localizedDescription }
        load()
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
                    Text("Subject, sender and one preview line of recent mail, indexed on this iPhone so Siri and Spotlight can find a thread. Never the message itself.")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            SiriTipView(intent: WhatNeedsReplyIntent())
            ShortcutsLink()
        } header: {
            Text("Siri & Search")
        } footer: {
            Text("Ask Siri what needs a reply or what's due, say \"remind me about this tomorrow\" on an open thread, or add any action to a Shortcut. Nothing is sent anywhere: Siri reads the index on this iPhone.")
        }
        .menuCard()
    }
}

// MARK: - Triage (Jev)

private struct TriageSection: View {
    @Environment(AppModel.self) private var model
    @State private var status: TriageStatus?
    @State private var key = ""
    @State private var saving = false
    @State private var error: String?
    @State private var confirmRemove = false
    @State private var newLabel = ""
    @State private var reanalyzeQueued = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                mark("TS")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jev").font(.body.weight(.medium))
                    Text(status?.configured == true ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                if status?.configured == true {
                    Button(confirmRemove ? "Really remove?" : "Remove", role: confirmRemove ? .destructive : nil) {
                        if confirmRemove { remove() } else { confirmRemove = true }
                    }
                    .font(.footnote.weight(.semibold))
                }
            }
            if status?.configured == true {
                Toggle("Auto-triage", isOn: Binding(get: { status?.enabled ?? false }, set: { setEnabled($0) }))
                HStack {
                    Button("Reanalyze all emails") {
                        do { try model.engine.reanalyzeTriage(); reanalyzeQueued = true } catch { self.error = error.localizedDescription }
                    }
                    .font(.footnote.weight(.semibold))
                    if reanalyzeQueued {
                        Text("Queued — processes gradually in the background.").font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let last = status?.lastError {
                    Text("Last run failed: \(last)").font(.footnote).foregroundStyle(.red)
                }
            } else {
                HStack {
                    SecureField("API key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .onSubmit { connect() }
                    Button(saving ? "Verifying…" : "Connect") { connect() }
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                        .font(.footnote.weight(.semibold))
                }
            }
            // The labels: the categories Jev sorts mail into, and the
            // segments of the bottom pill.
            ForEach(model.triageLabels) { l in
                Text(l.name)
                    .swipeActions {
                        Button(role: .destructive) { delete(l) } label: { Label("Remove", systemImage: "trash") }
                    }
            }
            if model.triageLabels.isEmpty {
                Text("No labels yet").font(.footnote).foregroundStyle(Theme.textTertiary)
            }
            HStack {
                TextField("New label name", text: $newLabel).onSubmit { add() }
                Button("Add") { add() }
                    .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
                    .font(.footnote.weight(.semibold))
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Triage")
        } footer: {
            Text("Jev sorts new mail into your own labels and flags a priority automatically, in the background — subject and snippet (never the full message) are sent to Jev to do this. Jev is a third-party classification service, not part of Hey Pigeon — see jevtypesafeai.com. The key stays on this device (paste it on each one); your labels and the switch sync to your other devices. Swipe a label left to remove it.")
        }
        .menuCard()
        .task { load() }
        .onChange(of: model.prefsVersion) { _, _ in load() }
    }

    private func load() { status = try? model.engine.triageStatus() }

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

// MARK: Notifications (the optional push relay — relay/README.md)

private struct NotificationsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let push = model.push
        Section {
            Toggle(isOn: Binding(get: { push.enabled }, set: { on in Task { await push.setEnabled(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("New mail (push)")
                    Text(statusLine).font(.caption).foregroundStyle(Theme.textTertiary)
                }
            }
            .disabled(push.busy || !push.canEnable)
            if let error = push.lastError { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Notifications")
        } footer: {
            Text("Goes through a small relay that only ever sees your address and a change counter, never mail; the notification text is composed on this phone. Turn it off and the app syncs on open and in the background instead. Reminders stay local either way.")
        }
        .menuCard()
        .onAppear { push.refreshStatus() }
    }

    /// One line under the toggle: state, then the sync lease when there is one.
    private var statusLine: String {
        let push = model.push
        if !push.canEnable { return "Not available in this build" }
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
