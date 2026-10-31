// The sidebar: the accounts (desktop 0/1/2) as a switch at the top, then
// the folders in the desktop sidebar's order with Scheduled and Need reply
// among them, the Gmail labels, and Add account · Settings at the bottom.
// The phone shows the same list as a sheet (Features/Sidebar/SidebarSheet).

import SwiftUI

struct SidebarColumn: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model

    /// The highlighted folder: what the list shows, unless a search is on.
    private var selection: Binding<MailView?> {
        Binding(
            get: { model.isSearching ? nil : model.view },
            set: { view in
                guard let view else { return }
                state.selection = []
                model.show(view)
                state.listFocusRequest += 1
            }
        )
    }

    private var labels: [MailLabelItem] {
        model.labels.filter { l in
            !l.id.hasPrefix("CATEGORY_") && (model.selectedAccountId == nil || l.accountId == model.selectedAccountId)
        }
    }

    var body: some View {
        List(selection: selection) {
            Section {
                AccountRow(id: nil, title: "All accounts", color: nil, selected: model.selectedAccountId == nil, unread: model.engineUnread(accountId: nil)) {
                    switchAccount(nil)
                }
                ForEach(model.accounts) { a in
                    AccountRow(id: a.id, title: a.displayName, color: a.color, selected: model.selectedAccountId == a.id,
                               unread: model.engineUnread(accountId: a.id),
                               disconnected: model.accountStates[a.id]?.isConnected == false) {
                        switchAccount(a.id)
                    }
                }
            } header: {
                Text("Accounts")
            }
            Section("Mail") {
                folder(.inbox)
                folder(.scheduled, count: model.scheduledCount, badge: model.dueCount)
                folder(.needReply, count: model.needReplyCount)
                folder(.starred)
                folder(.sent)
                folder(.drafts, count: model.draftsCount)
                folder(.archive)
                folder(.all)
                folder(.spam)
                folder(.trash)
            }
            if !labels.isEmpty {
                Section("Labels") {
                    ForEach(labels) { l in
                        folder(.label(id: l.id, name: l.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                Button { Task { await model.addAccount() } } label: { Label("Add account", systemImage: "plus.circle") }
                    .help("Add a Google account")
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .help("Settings (⌘,)")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .font(.subheadline)
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
    }

    private func switchAccount(_ id: String?) {
        model.selectedAccountId = id
        Haptics.light()
    }

    /// A folder row with its count; `badge` is the Scheduled row's due
    /// count, in the accent so a reminder that came due stands out.
    private func folder(_ view: MailView, count: Int? = nil, badge: Int = 0) -> some View {
        let n = count ?? model.counts[view.countKey] ?? 0
        return Label(view.title, systemImage: view.systemImage)
            .badge(Self.badgeText(count: n, due: badge))
            .tag(view)
    }

    /// The due count in the accent when there is one, else the plain count.
    static func badgeText(count: Int, due: Int) -> Text? {
        if due > 0 { return Text("\(due)").foregroundStyle(Theme.accent) }
        return count > 0 ? Text("\(count)") : nil
    }
}

/// One account (or "All accounts"): the colour dot, the name, its unread
/// count; a checkmark on the one the lists show.
private struct AccountRow: View {
    let id: String?
    let title: String
    let color: AccountColor?
    let selected: Bool
    let unread: Int
    var disconnected = false
    let action: () -> Void
    @Environment(AppModel.self) private var model

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let color {
                    Circle().fill(Theme.tagForeground(color)).frame(width: 9, height: 9)
                } else {
                    HStack(spacing: -3) {
                        ForEach(model.accounts.prefix(3)) { a in
                            Circle().fill(Theme.tagForeground(a.color)).frame(width: 9, height: 9)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.body.weight(selected ? .semibold : .regular)).lineLimit(1)
                    if disconnected {
                        Text("Disconnected").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 4)
                if unread > 0 {
                    Text("\(unread)").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary).monospacedDigit()
                }
                if selected {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Theme.textSecondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(unread) unread\(selected ? ", shown" : "")")
    }
}

extension AppModel {
    /// The unified or one account's unread inbox count, read from the store
    /// (the sidebar's per-account numbers; `counts` is the selected scope's).
    func engineUnread(accountId: String?) -> Int {
        (try? engine.unreadCounts(accountId: accountId))?["inbox"] ?? 0
    }
}
