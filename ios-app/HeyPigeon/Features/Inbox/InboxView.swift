// The list screens behind the tab bar. No title: two glass circles on top
// (sidebar, compose), the list starts right under them, and the account
// filter floats above the tab bar as a glass pill. One screen type serves
// Inbox, Scheduled and Need reply; Search is its own screen.

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
            // The title is for accessibility and the back button only; the
            // bar shows just the two circles.
            .navigationTitle(tab == .inbox ? model.folder.title : tab.title)
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { model.showSidebar = true } label: { Image(systemName: "line.3.horizontal") }
                        .accessibilityLabel("Folders and accounts")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { model.composeDraft = SendDraft() } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Compose")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.accounts.count > 1 { AccountSplitBar() }
            }
            .refreshable { await model.sync() }
            .navigationDestination(for: ThreadRow.self) { row in
                ThreadView(row: row) { path.removeLast() }
            }
        }
    }
}

/// Search tab: the field is the tab bar's search slot; results use the
/// same rows and gestures. Operators are Gmail's, exactly as on desktop.
struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @State private var path: [ThreadRow] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Group {
                if model.isSearching && model.groupedRows.isEmpty {
                    EmptyState(view: model.view, searching: true, lastSyncAt: model.lastSyncAt)
                } else if model.isSearching {
                    ThreadList(path: $path)
                } else {
                    ContentUnavailableView {
                        Label("Search your mail", systemImage: "magnifyingglass")
                            .font(Theme.display(22, relativeTo: .title2))
                    } description: {
                        Text("Instant, local, every account. Try  from:priya  ·  has:attachment  ·  is:unread  ·  label:invoices")
                    }
                }
            }
            .background(Theme.canvas)
            .navigationTitle("Search")
            .toolbarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .searchable(text: $model.searchText, prompt: "from: to: label: is:unread has:attachment")
            .navigationDestination(for: ThreadRow.self) { row in
                ThreadView(row: row) { path.removeLast() }
            }
        }
    }
}

/// Floating account filter (desktop 0/1/2) above the tab bar.
struct AccountSplitBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                segment(nil, title: "All", count: model.accounts.count, dot: nil)
                ForEach(model.accounts) { a in
                    segment(a.id, title: a.displayName, count: nil, dot: Theme.tagForeground(a.color))
                }
            }
            .padding(4)
        }
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private func segment(_ id: String?, title: String, count: Int?, dot: Color?) -> some View {
        let on = model.selectedAccountId == id
        return Button {
            model.selectedAccountId = id
            Haptics.light()
        } label: {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title).font(.subheadline.weight(on ? .bold : .medium))
                if let count { Text("\(count)").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textTertiary) }
            }
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(on ? Theme.card.opacity(0.95) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The flat list with the gesture map. Shared by every tab. Day headers
/// only where they carry meaning (the Scheduled view's due buckets).
struct ThreadList: View {
    @Binding var path: [ThreadRow]
    @Environment(AppModel.self) private var model

    private var showHeaders: Bool { model.view == .scheduled && !model.isSearching }

    var body: some View {
        List {
            ForEach(model.groupedRows, id: \.title) { group in
                Section {
                    ForEach(group.rows) { row in
                        ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                model.markRead(row)
                                path.append(row)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 8, trailing: 20))
                            .listRowBackground(Theme.canvas)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
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
                                    RowMenu(row: row)
                                } label: { Label("More", systemImage: "ellipsis") }
                                .tint(Theme.navy400)
                            }
                            .contextMenu { RowMenu(row: row) }
                            .onAppear { model.loadMoreIfNeeded(current: row) }
                    }
                } header: {
                    if showHeaders {
                        Text(group.title)
                            .font(Theme.display(13, relativeTo: .caption))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .animation(.easeOut(duration: 0.15), value: model.rows.map(\.id))
    }
}

/// The full action set — the command palette's row actions, on a long press.
struct RowMenu: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model

    var body: some View {
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

struct SkeletonList: View {
    var body: some View {
        List {
            ForEach(0..<8, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.navy100).frame(width: 140, height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.navy100).frame(height: 10)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.navy100).frame(width: 220, height: 10)
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
                Text("Try from:, to:, label:, is:unread or has:attachment.")
            } else if let lastSyncAt {
                Text("Up to date as of \(Formatters.rowTime(lastSyncAt)).")
            } else {
                Text("Pull down to sync.")
            }
        }
    }
}
