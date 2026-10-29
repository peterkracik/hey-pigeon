// The list screens behind the tab bar. The view's name sits between the
// glass circles on top (sidebar · AI, compose), the list starts right under
// them, and the Jev label filter floats above the tab bar as a glass pill.
// Accounts live in the sidebar. One screen type serves Inbox, Scheduled and
// Need reply; Search is its own screen (Features/Search).

import AppIntents
import SwiftUI

struct MailListScreen: View {
    let tab: MainTab
    @Environment(AppModel.self) private var model
    @State private var path: [ThreadRow] = []

    private var isActive: Bool { model.tab == tab }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if !model.hasLoadedOnce {
                    SkeletonList()
                } else if isActive && model.groupedRows.isEmpty {
                    EmptyState(view: model.view, searching: false, lastSyncAt: model.lastSyncAt)
                } else if isActive {
                    ThreadList(path: $path)
                } else {
                    Color.clear
                }
            }
            .background(Theme.canvas)
            // ListTitle is the principal item. No .toolbar(removing: .title)
            // here: the principal counts as the title and went with it.
            .navigationTitle(tab == .inbox ? model.folder.title : tab.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .barLeading) {
                    Button { model.showSidebar = true } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Folders and accounts")
                }
                // The context the screen was missing: folder, unread count,
                // and which account — tap to switch account (desktop 0/1/2).
                ToolbarItem(placement: .principal) { ListTitle(tab: tab) }
                if model.aiConfigured {
                    ToolbarItem(placement: .barTrailing) {
                        Button { model.openViewSummary() } label: { Image(systemName: "sparkles") }
                            .accessibilityLabel("Summarize this view")
                    }
                }
                // "Ask my inbox": on-device questions over the Spotlight index.
                if tab == .inbox && InboxAsk.isAvailable(model) {
                    ToolbarItem(placement: .barTrailing) {
                        Button { model.askSheet = AskPresentation() } label: { Image(systemName: "questionmark.bubble") }
                            .accessibilityLabel("Ask my inbox")
                    }
                }
                ToolbarItem(placement: .barTrailing) {
                    Button { model.composeDraft = SendDraft() } label: { Image(systemName: "square.and.pencil") }
                        .keyboardShortcut("n", modifiers: .command)
                        .accessibilityLabel("Compose")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if tab == .inbox && !model.triageLabels.isEmpty { TriageSplitBar() }
            }
            .refreshable { await model.sync() }
            .navigationDestination(for: ThreadRow.self) { row in
                ThreadView(row: row) { path.removeLast() }
            }
            // Notification tap: the inbox tab opens the thread it names.
            .onChange(of: model.pendingThreadId, initial: true) { _, id in
                guard tab == .inbox, let id, let row = model.row(forThreadId: id) else { return }
                model.pendingThreadId = nil
                path = [row]
            }
        }
    }
}

/// Folder title + unread count in the top bar, with the account next to it
/// when there is more than one; then tapping opens the account switcher.
struct ListTitle: View {
    let tab: MainTab
    @Environment(AppModel.self) private var model

    private var title: String { tab == .inbox ? model.folder.title : tab.title }
    private var count: Int {
        switch tab {
        case .inbox: model.counts[model.folder.countKey] ?? 0
        case .scheduled: model.scheduledCount
        case .needReply: model.needReplyCount
        case .search: 0
        }
    }

    var body: some View {
        if model.accounts.count > 1 {
            Menu { accountMenu } label: { label }
                .accessibilityLabel("\(title), \(count) unread. Switch account")
        } else {
            label.accessibilityElement(children: .ignore)
                .accessibilityLabel("\(title), \(count) unread")
                .accessibilityAddTraits(.isHeader)
        }
    }

    @ViewBuilder private var accountMenu: some View {
        Button {
            model.selectedAccountId = nil
        } label: {
            Label("All accounts", systemImage: model.selectedAccountId == nil ? "checkmark" : "circle.grid.2x2")
        }
        ForEach(model.accounts) { a in
            Button {
                model.selectedAccountId = a.id
                Haptics.light()
            } label: {
                Label(a.displayName, systemImage: a.id == model.selectedAccountId ? "checkmark" : "circle.fill")
            }
        }
    }

    private var label: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.display(17, relativeTo: .headline)).foregroundStyle(Theme.textPrimary)
            if count > 0 {
                Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textTertiary)
            }
            if model.accounts.count > 1 {
                if let a = model.currentAccount {
                    Circle().fill(Theme.tagForeground(a.color)).frame(width: 7, height: 7)
                    Text(a.displayName).font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
                } else {
                    HStack(spacing: -2) {
                        ForEach(model.accounts.prefix(3)) { a in
                            Circle().fill(Theme.tagForeground(a.color)).frame(width: 7, height: 7)
                        }
                    }
                    Text("All").font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

/// Floating filter above the tab bar: the folder title (no filter), then
/// the Jev triage labels from Settings — the desktop's label tabs under the
/// folder title. Accounts switch in the sidebar.
struct TriageSplitBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                segment(nil, title: model.folder.title, count: model.counts[model.folder.countKey] ?? 0)
                ForEach(model.triageLabels) { l in
                    segment(l.id, title: l.name, count: 0)
                }
            }
            .padding(4)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func segment(_ id: String?, title: String, count: Int) -> some View {
        let on = model.triageFilterId == id
        return Button {
            model.triageFilterId = id
            Haptics.light()
        } label: {
            HStack(spacing: 6) {
                Text(title).font(.subheadline.weight(on ? .bold : .medium))
                if count > 0 { Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textTertiary) }
            }
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? Theme.card.opacity(0.95) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The flat list with the gesture map and the desktop's day groups
/// (Pinned · Today · Last 7 days · Older; due buckets in Scheduled).
struct ThreadList: View {
    @Binding var path: [ThreadRow]
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            ForEach(model.groupedRows) { group in
                Section {
                    ForEach(group.rows) { row in cell(row) }
                } header: {
                    GroupHeader(group: group)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollDismissesKeyboard(.immediately)
        .animation(.easeOut(duration: 0.15), value: model.rows.map(\.id))
    }

    /// One row with its gestures, annotation and menu. Its own builder so
    /// the list body type-checks in reasonable time.
    private func cell(_ row: ThreadRow) -> some View {
        SwipeableRow(
            leading: [swipe(model.swipeActions[0], row), swipe(model.swipeActions[1], row)],
            trailing: [swipe(model.swipeActions[2], row), swipe(model.swipeActions[3], row)],
            background: Theme.card
        ) {
            ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil,
                          highlight: model.tab == .search ? model.searchTerms : [])
                .padding(.horizontal, 16).padding(.vertical, 7)
                .contentShape(Rectangle())
                // Unread marker: a bar on the left edge, flush with the screen.
                .overlay(alignment: .leading) {
                    if !row.isRead { Rectangle().fill(Theme.unreadBar).frame(width: 3) }
                }
                .onTapGesture {
                    Keyboard.dismiss()
                    if model.view == .drafts { model.openDraft(row); return }
                    model.markRead(row)
                    path.append(row)
                }
        }
        // View Annotations (iOS 27): Siri sees this row as the
        // thread entity, so "mark these done", "remind me about
        // the second one" and "archive everything from Lufthansa
        // here" resolve against what is on screen.
        .appEntityIdentifier(MailThreadEntity.identifier(row.id))
        .padding(.bottom, 1) // the gap between rows, canvas showing through
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu { RowMenu(row: row) }
        .onAppear { model.loadMoreIfNeeded(current: row) }
    }

    private func swipe(_ action: RowAction, _ row: ThreadRow) -> SwipeAction {
        switch action {
        case .done:
            SwipeAction(title: row.isDone ? "Not done" : "Done", systemImage: row.isDone ? "arrow.uturn.backward" : "checkmark",
                        tint: Theme.accent) { model.run(.done, on: row) }
        case .delete:
            SwipeAction(title: "Delete", systemImage: "trash", tint: Color(hex: 0xB34E2E)) { model.run(.delete, on: row) }
        case .remind:
            SwipeAction(title: row.scheduledAt == nil ? "Remind" : "Remove reminder",
                        systemImage: row.scheduledAt == nil ? "clock" : "clock.badge.xmark",
                        tint: Theme.navy700) { model.run(.remind, on: row) }
        case .needReply:
            SwipeAction(title: row.needsReply ? "No reply needed" : "Need reply", systemImage: "arrowshape.turn.up.left",
                        tint: Color(hex: 0x2A6BAE)) { model.run(.needReply, on: row) }
        case .pin:
            SwipeAction(title: row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin",
                        tint: Color(hex: 0xA9761E)) { model.run(.pin, on: row) }
        case .read:
            SwipeAction(title: row.isRead ? "Unread" : "Read", systemImage: row.isRead ? "envelope.badge" : "envelope.open",
                        tint: Theme.navy500) { model.run(.read, on: row) }
        }
    }
}

/// Day-group label in the desktop's small grey style. The AI summary of
/// the whole view is the sparkle in the top bar.
struct GroupHeader: View {
    let group: RowGroup
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack {
            Text(group.title)
                .font(Theme.display(13, relativeTo: .caption))
                .foregroundStyle(group.isPinned ? Theme.textSecondary : Theme.textTertiary)
                .textCase(nil)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

/// The full action set — the desktop command palette's row actions, on a
/// long press, in the desktop's words.
struct RowMenu: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model

    private var accountLabels: [MailLabelItem] {
        model.labels.filter { $0.accountId == row.accountId && !$0.id.hasPrefix("CATEGORY_") }
    }

    var body: some View {
        Button {
            if !row.isDone { IntentDonations.archived(row, in: model) }
            model.toggleDone(row)
        } label: {
            Label(row.isDone ? "Mark not done" : "Mark done", systemImage: row.isDone ? "arrow.uturn.backward" : "checkmark")
        }
        Button { model.pendingRemind = row } label: {
            Label(row.scheduledAt == nil ? "Remind me" : "Change reminder", systemImage: "clock")
        }
        Button { model.togglePin(row) } label: {
            Label(row.isPinned ? "Unpin" : "Pin", systemImage: row.isPinned ? "pin.slash" : "pin")
        }
        Button { model.toggleNeedsReply(row) } label: {
            Label(row.needsReply ? "Clear need reply" : "Need reply", systemImage: "arrowshape.turn.up.left")
        }
        Button { model.toggleRead(row) } label: {
            Label(row.isRead ? "Mark unread" : "Mark read", systemImage: row.isRead ? "envelope.badge" : "envelope.open")
        }
        if !accountLabels.isEmpty {
            Menu {
                ForEach(accountLabels) { label in
                    Button { IntentDonations.labeled(row, label, on: true, in: model); model.move(row, to: label) } label: { Label(label.name, systemImage: "tray") }
                }
            } label: { Label("Move to folder", systemImage: "folder") }
            Menu {
                ForEach(accountLabels) { label in
                    let on = row.labels.contains(label.id)
                    Button { IntentDonations.labeled(row, label, on: !on, in: model); model.setLabel(row, label, on: !on) } label: {
                        Label(on ? "Remove \(label.name)" : label.name, systemImage: on ? "checkmark" : "tag")
                    }
                }
            } label: { Label("Add label", systemImage: "tag") }
        }
        if !model.triageLabels.isEmpty {
            Menu {
                ForEach(model.triageLabels) { label in
                    let on = row.triageLabelIds.contains(label.id)
                    Button {
                        var ids = row.triageLabelIds
                        if on { ids.removeAll { $0 == label.id } } else { ids.append(label.id) }
                        model.setTriageLabels(row, ids)
                    } label: { Label(label.name, systemImage: on ? "checkmark" : "sparkles") }
                }
            } label: { Label("Jev labels", systemImage: "sparkles") }
        }
        Divider()
        Button(role: .destructive) { IntentDonations.deleted(row, in: model); model.delete(row) } label: { Label("Delete", systemImage: "trash") }
    }
}

struct SkeletonList: View {
    var body: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.sunken).frame(width: 140, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.sunken).frame(height: 10)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.sunken).frame(width: 220, height: 10)
                }
                .padding(.vertical, 8)
                .listRowBackground(Theme.canvas)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .redacted(reason: .placeholder)
    }
}

/// The empty inbox is a designed moment, not a shrug.
struct EmptyState: View {
    let view: MailView
    let searching: Bool
    let lastSyncAt: Date?

    var body: some View {
        ContentUnavailableView {
            Label(searching ? "No matches" : (view == .inbox ? "All clear" : "Nothing here"),
                  systemImage: searching ? "magnifyingglass" : "bird")
                .font(Theme.display(22, relativeTo: .title2))
        } description: {
            if searching {
                Text("Try other words or remove a filter.")
            } else if let lastSyncAt {
                Text("Up to date as of \(Formatters.rowTime(lastSyncAt)).")
            } else {
                Text("Pull down to sync.")
            }
        }
    }
}
