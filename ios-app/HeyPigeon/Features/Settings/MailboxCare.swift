// Three Settings sections about the mailbox's upkeep, the same on the phone
// and the Mac:
//
// - Outbox: the changes still on their way to Gmail and the ones Gmail
//   refused until the engine stopped trying (it used to keep those without
//   a word, and this device and Gmail then disagreed for good). Each can
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
                        .foregroundStyle(model.failedChanges > 0 ? Theme.accent : Theme.textTertiary)
                }
            }
        } header: {
            Text("Outbox")
        } footer: {
            Text("What you do is applied on this \(Device.name) at once and sent to Gmail after. A change Gmail keeps refusing waits here for you to send again or discard.")
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

/// The outbox, oldest first: what each change is, how often it was tried,
/// what Gmail said, and the two ways out of a stuck one.
struct OutboxView: View {
    @Environment(AppModel.self) private var model
    @State private var changes: [QueuedChange] = []
    @State private var busy: Int64?

    var body: some View {
        List {
            if changes.isEmpty {
                Text("Nothing is waiting. Everything you did has reached Gmail.")
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(changes) { change in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(change.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                        if change.failed {
                            Text("Not sent").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        Spacer()
                        if busy == change.id { ProgressView().controlSize(.small) }
                    }
                    Text(change.summary).font(.footnote).foregroundStyle(Theme.textSecondary).lineLimit(2)
                    if let error = change.lastError, !error.isEmpty {
                        Text(error).font(.caption).foregroundStyle(Theme.textTertiary).lineLimit(3)
                    }
                    HStack(spacing: 12) {
                        Button("Send again") {
                            busy = change.id
                            Task {
                                await model.retryQueued(change)
                                busy = nil
                                load()
                            }
                        }
                        Button("Discard", role: .destructive) {
                            model.discardQueued(change)
                            load()
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.footnote.weight(.semibold))
                    .disabled(busy != nil)
                    .padding(.top, 2)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Outbox")
        .inlineNavigationTitle()
        .onAppear { load() }
        // The engine drains in the background: follow it.
        .onChange(of: model.reloadCount) { _, _ in load() }
    }

    private func load() {
        let next = model.outbox()
        if next != changes { changes = next }
    }
}

// MARK: - Muted and blocked

struct RulesSection: View {
    @Environment(AppModel.self) private var model
    /// The muted threads' subjects, read from the store when the section shows.
    @State private var subjects: [String: String] = [:]

    var body: some View {
        if !model.mutedThreads.isEmpty || !model.blockedSenders.isEmpty {
            Section {
                ForEach(model.blockedSenders, id: \.self) { address in
                    HStack {
                        Label(address, systemImage: "hand.raised.slash")
                        Spacer()
                        Button("Unblock") { model.unblock(address) }
                            .buttonStyle(.borderless)
                    }
                }
                ForEach(model.mutedThreads.reversed(), id: \.self) { id in
                    HStack {
                        Label(subjects[id] ?? "A muted thread", systemImage: "bell.slash").lineLimit(1)
                        Spacer()
                        Button("Unmute") { model.unmute(threadId: id) }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                // The subjects are read here, on one view: a section hands
                // its modifiers to every row.
                Text("Muted and blocked")
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
            } footer: {
                Text("A muted thread is marked done again whenever a reply arrives; mail from a blocked address goes to Spam. Both are this app's own rules, applied on each of your devices after a sync, and kept with your other settings in your Google Drive.")
            }
            .menuCard()
        }
    }
}

// MARK: - Diagnostics

struct DiagnosticsSection: View {
    @Environment(AppModel.self) private var model
    @State private var reports: [DiagnosticsCollector.Report] = []

    var body: some View {
        Section {
            if reports.isEmpty {
                Text("No crash or hang reports.").foregroundStyle(Theme.textSecondary)
            } else {
                ForEach(reports.prefix(5)) { report in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Formatters.fullDate(report.date))
                            Text(ByteCountFormatter.string(fromByteCount: Int64(report.bytes), countStyle: .file))
                                .font(.caption).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Copy") {
                            if let text = try? String(contentsOf: report.url, encoding: .utf8) {
                                Clipboard.copy(text)
                                model.show("Report copied")
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("Delete all reports", role: .destructive) {
                    DiagnosticsCollector.deleteAll()
                    reports = []
                }
            }
        } header: {
            Text("Diagnostics")
                .onAppear { reports = DiagnosticsCollector.reports() }
        } footer: {
            Text("When the app crashes or hangs, the system gives it a report the next day. The reports stay on this \(Device.name): nothing is sent anywhere unless you copy one out.")
        }
        .menuCard()
    }
}
