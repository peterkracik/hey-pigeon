// The root screen: an inbox that reads like a todo list. No tab bar, no
// toolbar rows — the title is the view switcher, the avatar chip is the
// account switcher, search is the pull-down field, compose is the one button.

import SwiftUI

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ThreadRow] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Group {
                if !model.hasLoadedOnce {
                    SkeletonList()
                } else if model.groupedRows.isEmpty {
                    EmptyState(view: model.view, searching: model.isSearching, lastSyncAt: model.lastSyncAt)
                } else {
                    threadList
                }
            }
            .background(Theme.canvas)
            .navigationTitle(model.view.title)
            .navigationBarTitleDisplayMode(.large)
            .toolbarTitleMenu { ViewsMenu() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showAccounts = true } label: { AccountChip() }
                        .accessibilityLabel("Accounts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.composeDraft = SendDraft() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Compose")
                }
            }
            .searchable(text: $model.searchText, placement: .navigationBarDrawer(displayMode: .automatic),
                        prompt: "Search · from: to: label: is:unread has:attachment")
            .refreshable { await model.sync() }
            .navigationDestination(for: ThreadRow.self) { row in
                ThreadView(row: row) { path.removeLast() }
            }
        }
    }

    private var threadList: some View {
        List {
            if model.triageLevelsPresent && !model.isSearching {
                TriageChips().listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
            }
            ForEach(model.groupedRows, id: \.title) { group in
                Section {
                    ForEach(group.rows) { row in
                        ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.markRead(row)
                                path.append(row)
                            }
                            .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                            .listRowBackground(Theme.card)
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button { model.archive(row) } label: { Label("Archive", systemImage: "checkmark") }
                                    .tint(Theme.accent)
                                Button { model.toggleRead(row) } label: {
                                    Label(row.isRead ? "Unread" : "Read", systemImage: row.isRead ? "envelope.badge" : "envelope.open")
                                }
                                .tint(Theme.navy500)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button { model.pendingRemind = row } label: { Label("Remind", systemImage: "clock") }
                                    .tint(Theme.navy700)
                                Button { model.toggleNeedsReply(row) } label: {
                                    Label("Need reply", systemImage: "arrowshape.turn.up.left")
                                }
                                .tint(Theme.navy500)
                                Menu {
                                    rowMenu(row)
                                } label: { Label("More", systemImage: "ellipsis") }
                                .tint(Theme.navy400)
                            }
                            .contextMenu { rowMenu(row) }
                            .onAppear { model.loadMoreIfNeeded(current: row) }
                    }
                } header: {
                    Text(group.title)
                        .font(Theme.display(13, relativeTo: .caption))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .animation(.easeOut(duration: 0.15), value: model.rows.map(\.id))
    }

    /// The full action set — the command palette's row actions, on a long press.
    @ViewBuilder
    private func rowMenu(_ row: ThreadRow) -> some View {
        if row.isArchived {
            Button { model.unarchive(row) } label: { Label("Move to inbox", systemImage: "tray.and.arrow.down") }
        } else {
            Button { model.archive(row) } label: { Label("Archive", systemImage: "checkmark") }
        }
        Button { model.toggleRead(row) } label: {
            Label(row.isRead ? "Mark unread" : "Mark read", systemImage: row.isRead ? "envelope.badge" : "envelope.open")
        }
        Button { model.toggleStar(row) } label: {
            Label(row.isStarred ? "Unstar" : "Star", systemImage: row.isStarred ? "star.slash" : "star")
        }
        Button { model.pendingRemind = row } label: {
            Label(row.scheduledAt == nil ? "Remind me…" : "Change reminder…", systemImage: "clock")
        }
        Button { model.toggleNeedsReply(row) } label: {
            Label(row.needsReply ? "Doesn't need reply" : "Need reply", systemImage: "arrowshape.turn.up.left")
        }
        if !model.labels.isEmpty {
            Menu {
                ForEach(model.labels.filter { $0.accountId == row.accountId }) { label in
                    let on = row.labels.contains(label.id)
                    Button {
                        Task { try? await model.engine.perform(.modifyLabel(threadId: row.id, labelId: label.id, add: !on), accountId: row.accountId) }
                    } label: { Label(label.name, systemImage: on ? "checkmark" : "tag") }
                }
            } label: { Label("Labels", systemImage: "tag") }
        }
        Divider()
        Button(role: .destructive) { model.trash(row) } label: { Label("Trash", systemImage: "trash") }
    }
}

/// Stacked account dots; the current account's name when filtered.
struct AccountChip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -6) {
                ForEach(model.accounts.prefix(3)) { a in
                    Circle()
                        .fill(Theme.tagForeground(a.color))
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(Theme.canvas, lineWidth: 2))
                        .opacity(model.selectedAccountId == nil || model.selectedAccountId == a.id ? 1 : 0.35)
                }
            }
            if let a = model.currentAccount {
                Text(a.displayName).font(.subheadline.weight(.semibold))
            }
        }
    }
}

/// The sidebar, as the title's menu.
struct ViewsMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(MailView.folders, id: \.self) { v in
            Button {
                model.view = v
            } label: {
                let n = model.counts[v.countKey] ?? 0
                Label(n > 0 ? "\(v.title)  \(n)" : v.title, systemImage: v.systemImage)
            }
        }
        if !model.labels.isEmpty {
            Divider()
            ForEach(model.labels) { l in
                Button { model.view = .label(id: l.id, name: l.name) } label: { Label(l.name, systemImage: "tag") }
            }
        }
    }
}

/// Jev priority filter, shown only when the engine has triage data.
struct TriageChips: View {
    @State private var selected: TriageLevel?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All")
                chip(.high, "High")
                chip(.medium, "Medium")
                chip(.low, "Low")
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }

    private func chip(_ level: TriageLevel?, _ title: String) -> some View {
        let on = selected == level
        return Button { selected = level } label: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Theme.textPrimary : Theme.card, in: Capsule())
                .foregroundStyle(on ? Theme.card : Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}

struct SkeletonList: View {
    var body: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.navy100).frame(width: 140, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.navy100).frame(height: 10)
                }
                .padding(.vertical, 8)
                .listRowBackground(Theme.card)
            }
        }
        .listStyle(.insetGrouped)
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
                Text("Try from:, to:, label:, is:unread or has:attachment.")
            } else if let lastSyncAt {
                Text("Up to date as of \(Formatters.rowTime(lastSyncAt)).")
            } else {
                Text("Pull down to sync.")
            }
        }
    }
}
