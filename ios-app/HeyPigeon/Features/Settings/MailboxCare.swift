// Three Settings sections about the mailbox's upkeep, the same on the phone
// and the Mac:
//
// - Outbox: the changes still on their way to Gmail and the ones that
//   could not be sent (the engine used to keep those without a word, and
//   this device and Gmail then disagreed for good). One that is stuck can
//   be sent again or discarded.
// - Muted and blocked: the app's own rules (Gmail's API has no mute, and
//   its filters need a permission the app does not ask for). The core
//   applies them at the end of every sync, on every device.
// - Diagnostics: the crash and hang reports the system hands the app,
//   kept on this device (Shared/Diagnostics.swift).

import SwiftUI

// MARK: - Outbox

struct OutboxSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Section {
            NavigationLink {
                OutboxView()
            } label: {
                HStack {
                    Label("Outbox", systemImage: model.failedChanges > 0 ? "exclamationmark.triangle" : "tray.and.arrow.up")
                    Spacer()
                    Text(Self.status(waiting: model.queuedChanges, failed: model.failedChanges))
                        .foregroundStyle(model.failedChanges > 0 ? Theme.warning : Theme.textTertiary)
                }
            }
        } footer: {
            Text("What you do is applied on this \(Device.name) at once and sent to Gmail after. A change that could not be sent waits in the Outbox for you to send again or discard.")
        }
        .menuCard()
    }

    /// "Empty", "3 waiting", "1 not sent", "3 waiting · 1 not sent".
    static func status(waiting: Int, failed: Int) -> String {
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) waiting") }
        if failed > 0 { parts.append("\(failed) not sent") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }
}

/// The outbox, oldest first: what each change is, how often it was tried
/// and why it did not go, and the two ways out of one that is stuck. A
/// change still on its way has no buttons: it needs no help, and a
/// "Discard" beside a message about to leave is one tap from losing it.
struct OutboxView: View {
    @Environment(AppModel.self) private var model
    @State private var changes: [QueuedChange] = []
    @State private var busy: Int64?
    /// Why the last "Send again" or "Discard" of a row did nothing.
    @State private var notes: [Int64: String] = [:]
    /// A send asked to be discarded: confirmed first, it is someone's mail.
    @State private var discarding: QueuedChange?

    var body: some View {
        SettingsList {
            Section {
                if changes.isEmpty {
                    Text("Nothing is waiting. Everything you did has reached Gmail.")
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(changes) { change in row(change) }
            }
            .menuCard()
        }
        .navigationTitle("Outbox")
        .inlineNavigationTitle()
        // As the page appears, and again whenever the engine's background
        // drain changed something (a reload landed).
        .task(id: model.reloadCount) { await load() }
        .confirmationDialog("Discard this message?", isPresented: Binding(get: { discarding != nil }, set: { if !$0 { discarding = nil } }),
                            titleVisibility: .visible) {
            Button("Discard message", role: .destructive) {
                if let change = discarding { discard(change) }
                discarding = nil
            }
        } message: {
            Text("It will not be sent, and it is not kept as a draft.")
        }
    }

    private func row(_ change: QueuedChange) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(change.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(change.failed ? "Not sent" : "Waiting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(change.failed ? Theme.warning : Theme.textTertiary)
                Spacer()
                if busy == change.id { ProgressView().controlSize(.small) }
            }
            Text(change.summary).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
            if let error = notes[change.id] ?? change.lastError, !error.isEmpty {
                Text(error).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(3)
            }
            if change.failed {
                HStack(spacing: 16) {
                    Button("Send again") { retry(change) }
                    Button("Discard", role: .destructive) {
                        if change.kind == "send" { discarding = change } else { discard(change) }
                    }
                }
                .buttonStyle(.borderless)
                .font(.footnote.weight(.semibold))
                .disabled(busy != nil)
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func retry(_ change: QueuedChange) {
        busy = change.id
        Task {
            notes[change.id] = await model.retryQueued(change).map { "Still not sent: \($0)" }
            busy = nil
            await load()
        }
    }

    private func discard(_ change: QueuedChange) {
        busy = change.id
        Task {
            notes[change.id] = await model.discardQueued(change).map { "Not discarded: \($0)" }
            busy = nil
            await load()
        }
    }

    private func load() async {
        let next = await model.outbox()
        if !Task.isCancelled, next != changes { changes = next }
    }
}

// MARK: - Muted and blocked

/// One row, shown only while there is a rule: the lists themselves are a
/// page of their own (there can be hundreds of muted threads).
struct RulesSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.mutedThreads.isEmpty || !model.blockedSenders.isEmpty {
            Section {
                NavigationLink {
                    RulesView()
                } label: {
                    HStack {
                        Label("Muted and blocked", systemImage: "bell.slash")
                        Spacer()
                        Text(Self.status(muted: model.mutedThreads.count, blocked: model.blockedSenders.count))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
            } footer: {
                Text("A muted thread is marked done again when a reply arrives; a thread whose mail is all from a blocked address goes to Spam. Both are this app's own rules, applied on each of your devices after a sync, and kept with your other settings in your Google Drive.")
            }
            .menuCard()
        }
    }

    /// "2 muted", "1 blocked", "2 muted · 1 blocked".
    static func status(muted: Int, blocked: Int) -> String {
        var parts: [String] = []
        if muted > 0 { parts.append("\(muted) muted") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        return parts.joined(separator: " · ")
    }
}

/// The blocked addresses and the muted threads, each with its way back.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    /// The muted threads' subjects, read from the store when the page shows.
    @State private var subjects: [String: String] = [:]

    var body: some View {
        SettingsList {
            if !model.blockedSenders.isEmpty {
                Section("Blocked") {
                    ForEach(model.blockedSenders, id: \.self) { address in
                        HStack {
                            Text(address).lineLimit(1)
                            Spacer()
                            Button("Unblock") { model.unblock(address) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .menuCard()
            }
            if !model.mutedThreads.isEmpty {
                Section("Muted") {
                    ForEach(model.mutedThreads.reversed(), id: \.self) { id in
                        HStack {
                            Text(subjects[id] ?? "A muted thread").lineLimit(1)
                            Spacer()
                            Button("Unmute") { model.unmute(threadId: id) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .menuCard()
            }
            if model.blockedSenders.isEmpty && model.mutedThreads.isEmpty {
                Section { Text("Nothing is muted or blocked.").foregroundStyle(Theme.textSecondary) }
                    .menuCard()
            }
        }
        .navigationTitle("Muted and blocked")
        .inlineNavigationTitle()
        .task(id: model.mutedThreads) {
            let ids = model.mutedThreads
            let found = try? await model.engine.readInBackground { store in
                var out: [String: String] = [:]
                for id in ids {
                    if let row = try store.threadRow(id: id) { out[id] = row.subject.isEmpty ? "(no subject)" : row.subject }
                }
                return out
            }
            if let found, !Task.isCancelled { subjects = found }
        }
    }
}

// MARK: - Diagnostics

/// Shown only when there is a report: most days there is none, and an
/// empty section is one more thing to scroll past. Settings reads the
/// reports as it appears and hands them in: a section that shows nothing
/// has no view to read them from.
struct DiagnosticsSection: View {
    @Binding var reports: [DiagnosticsCollector.Report]
    /// The report just copied, so its button can say so: on the phone
    /// Settings is a sheet over the toasts.
    @State private var copied: URL?

    var body: some View {
        if !reports.isEmpty {
            Section {
                ForEach(reports.prefix(5)) { report in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatters.fullDate(report.date))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(report.bytes), countStyle: .file))
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button(copied == report.url ? "Copied" : "Copy") {
                            if let text = try? String(contentsOf: report.url, encoding: .utf8) {
                                Clipboard.copy(text)
                                copied = report.url
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Delete all reports", role: .destructive) {
                    DiagnosticsCollector.deleteAll()
                    reports = []
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("When the app crashes or hangs, the system hands it a report soon after. The reports are kept on this \(Device.name) only, out of its backups: nothing is sent anywhere unless you copy one out.")
            }
            .menuCard()
        }
    }
}
