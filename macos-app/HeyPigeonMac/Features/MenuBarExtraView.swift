// The menu bar extra: the unread count on the icon, and a small window
// with what is due, what needs a reply and the two things you do most
// from anywhere — a new message and a check for mail. Settings ›
// Appearance turns it off. The window is the paper: each list under its
// light grey title, its rows ruled, New message the one ink capsule.

import AppKit
import SwiftUI

/// The icon in the menu bar, with the unread count next to it.
struct MenuBarExtraLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The model's snapshot (observed): the label follows every reload.
        let unread = model.inboxUnreadAllAccounts
        let due = AppModel.due(model.scheduledAcrossAccounts).count
        if unread + due > 0 {
            Label("\(unread + due)", systemImage: due > 0 ? "envelope.badge.clock" : "envelope.badge")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "envelope")
        }
    }
}

struct MenuBarExtraView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var due: [ThreadRow] {
        AppModel.due(model.scheduledAcrossAccounts).sorted { ($0.scheduledAt ?? .distantPast) < ($1.scheduledAt ?? .distantPast) }
    }

    /// From the last reload's snapshot, like the widgets.
    private var needReply: [ThreadRow] { Array(model.needReplyAcrossAccounts.prefix(5)) }

    /// The newest unread inbox threads across accounts, read off the main
    /// actor each time a reload lands (the three lists used to be five
    /// store queries on the main thread on every render of the window).
    @State private var unread: [ThreadRow] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Hey Pigeon").font(Theme.display(17, relativeTo: .headline)).tracking(-0.2)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if model.isSyncing {
                    ProgressView().controlSize(.mini)
                } else if let at = model.lastSyncAt {
                    Text("Synced \(Formatters.rowTime(at))").font(Theme.mono(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            if !due.isEmpty {
                section("Due now", due.prefix(4), time: { $0.scheduledAt.map { Formatters.reminder($0) } ?? "" })
            }
            if !needReply.isEmpty {
                section("Need reply", needReply.prefix(3), time: { Formatters.rowTime($0.lastMessageAt) })
            }
            section(unread.isEmpty ? "Inbox" : "Unread · \(unread.count)", unread.prefix(5), time: { Formatters.rowTime($0.lastMessageAt) })
            if unread.isEmpty && due.isEmpty && needReply.isEmpty {
                Label {
                    Text("All clear").font(Theme.sans(size: 13))
                } icon: {
                    Image(systemName: "bird").font(.system(size: 13))
                }
                .foregroundStyle(Theme.textSecondary)
            }
            SectionRule()
            // New message is the window's ink action; Check is outlined,
            // and the way to the app plain words.
            HStack(spacing: 6) {
                Button { open(); model.compose(SendDraft()) } label: { pill("New message", systemImage: "square.and.pencil") }
                    .pillButton(prominent: true)
                Button { Task { await model.sync(manual: true) } } label: { pill("Check", systemImage: "arrow.clockwise") }
                    .pillButton()
                Spacer()
                Button("Open Hey Pigeon") { open() }
                    .buttonStyle(.plain)
                    .font(Theme.sans(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(14)
        .frame(width: 360)
        .background(Theme.raised)
        .task(id: model.reloadCount) {
            let rows = try? await model.engine.readInBackground { store in
                try store.threads(in: .inbox, accountId: nil, before: nil, limit: 20).filter { !$0.isRead }
            }
            if let rows, !Task.isCancelled, rows != unread { unread = rows }
        }
    }

    /// One of the window's lists under its title: the account's dot where
    /// accounts mix, the sender (bold under the highlighter while unread)
    /// over the subject, the time in the mono, a hairline between rows.
    @ViewBuilder
    private func section(_ title: String, _ rows: ArraySlice<ThreadRow>, time: @escaping (ThreadRow) -> String) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SectionTitle(title).padding(.bottom, 2)
                ForEach(rows) { row in
                    Button { open(thread: row.id) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let a = model.account(for: row), model.accountsById.count > 1 {
                                Circle().fill(Theme.state(a.color)).frame(width: 6, height: 6)
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.fromSummary)
                                    .font(Theme.sender(!row.isRead))
                                    .foregroundStyle(row.isRead ? Theme.textSecondary : Theme.textPrimary)
                                    .lineLimit(1)
                                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                                    .font(Theme.sans(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(time(row)).font(Theme.mono(size: 11))
                                .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textPrimary)
                        }
                        .padding(.vertical, 7).padding(.horizontal, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) {
                        if row.id != rows.last?.id { RowRule() }
                    }
                }
            }
        }
    }

    /// A small button's label: the words in the app's face, the glyph in
    /// the system's.
    private func pill(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title).font(Theme.sans(size: 12, weight: .semibold))
        } icon: {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
        }
    }

    /// Bring the main window forward (opening one when none is up).
    private func open(thread id: String? = nil) {
        NSApp.activate()
        openWindow(id: MacWindows.main)
        if let id { model.openThread(id: id) }
    }
}
