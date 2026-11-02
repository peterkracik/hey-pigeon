// The sidebar, in the Claude desktop app's manner: a grey column under the
// traffic lights with the sidebar and back buttons beside them, the
// actions (New message, Search) as plain rows, the main folders with no
// header, then "Folders" and "Labels" as small grey headers that fold
// their rows away, and at the bottom the account — its initial, its name,
// a chevron that opens the switch (All accounts, each account, Add
// account) — beside the Settings gear. A row only tints: on hover, and a
// stronger tint on the folder the list shows. The phone shows the same
// list as a sheet (Features/Sidebar/SidebarSheet); here ⌃⌘S and the
// buttons slide it in and out, and a folder picked here closes the open
// thread.

import SwiftUI

struct SidebarColumn: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarFoldersOpen") private var foldersOpen = true
    @AppStorage("sidebarLabelsOpen") private var labelsOpen = true

    private var labels: [MailLabelItem] {
        model.labels.filter { l in
            !l.id.hasPrefix("CATEGORY_") && (model.selectedAccountId == nil || l.accountId == model.selectedAccountId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    SidebarRow(title: "New message", systemImage: "plus", help: "New message (⌘N)") {
                        model.compose(SendDraft())
                    }
                    SidebarRow(title: "Search", systemImage: "magnifyingglass", help: "Search (/)",
                               selected: state.searching || model.isSearching) {
                        state.run(.search, in: model)
                    }
                    if model.tab == .inbox && InboxAsk.isAvailable(model) {
                        SidebarRow(title: "Ask my inbox", systemImage: "questionmark.bubble", help: "Ask my inbox (⌥⌘A)") {
                            model.askSheet = AskPresentation()
                        }
                    }

                    Spacer().frame(height: 14)
                    folder(.inbox)
                    folder(.scheduled, count: model.scheduledCount, badge: model.dueCount)
                    folder(.needReply, count: model.needReplyCount)
                    folder(.starred)
                    folder(.drafts, count: model.draftsCount)

                    SectionHeader(title: "Folders", open: $foldersOpen)
                    if foldersOpen {
                        folder(.sent)
                        folder(.archive)
                        folder(.all)
                        folder(.spam)
                        folder(.trash)
                    }

                    if !labels.isEmpty {
                        SectionHeader(title: "Labels", open: $labelsOpen)
                        if labelsOpen {
                            ForEach(labels) { l in
                                folder(.label(id: l.id, name: l.name))
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Hairline()
            AccountFooter()
        }
        .background(MacTheme.sidebar)
    }

    /// The traffic lights' row: the room they take, then the sidebar and
    /// back buttons beside them.
    private var topRow: some View {
        HStack(spacing: 2) {
            Color.clear.frame(width: MacLayout.trafficLights, height: 1)
            IconButton("sidebar.leading", help: "Hide the sidebar (⌃⌘S)") { state.run(.toggleSidebar, in: model) }
            IconButton("chevron.left", help: "Back to the list (Esc)", disabled: !state.isThreadOpen) {
                state.run(.back, in: model)
            }
            Spacer()
        }
        .titleRow()
    }

    /// A folder row with its count; `badge` is the Scheduled row's due
    /// count, in the accent so a reminder that came due stands out.
    private func folder(_ view: MailView, count: Int? = nil, badge: Int = 0) -> some View {
        let n = count ?? model.counts[view.countKey] ?? 0
        let selected = !model.isSearching && !state.searching && model.view == view
        return SidebarRow(title: view.title, systemImage: view.systemImage, help: view.title,
                          selected: selected, trailing: Self.badgeText(count: n, due: badge)) {
            state.run(.go(view), in: model)
        }
    }

    /// The due count in the accent when there is one, else the plain count.
    static func badgeText(count: Int, due: Int) -> Text? {
        if due > 0 { return Text("\(due)").foregroundStyle(Theme.accent) }
        return count > 0 ? Text("\(count)") : nil
    }
}

/// One sidebar row: an icon, a title, an optional count; tinted on hover
/// and when it is the shown folder.
private struct SidebarRow: View {
    let title: String
    let systemImage: String
    let help: String
    var selected = false
    var trailing: Text?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let trailing {
                    trailing
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return MacTheme.selected }
        return hovering ? MacTheme.hover : .clear
    }
}

/// A small grey group header with a chevron that folds its rows away.
private struct SectionHeader: View {
    let title: String
    @Binding var open: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { open.toggle() }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(open ? 0 : -90))
                Spacer()
            }
            .foregroundStyle(MacTheme.sectionHeader)
            .padding(.horizontal, 8)
            .padding(.top, 18).padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(open ? "expanded" : "collapsed")")
    }
}

/// The sidebar's foot: the shown account (its initial on its colour, its
/// name, the unread count) as a menu that switches it, and Settings.
private struct AccountFooter: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    private var name: String { model.currentAccount?.displayName ?? (model.accounts.isEmpty ? "No account" : "All accounts") }
    private var detail: String {
        let unread = model.engineUnread(accountId: model.selectedAccountId)
        if let a = model.currentAccount, a.email != a.displayName { return a.email }
        return unread > 0 ? "\(unread) unread" : "Up to date"
    }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                Button { switchAccount(nil) } label: {
                    Label("All accounts", systemImage: model.selectedAccountId == nil ? "checkmark" : "tray.2")
                }
                ForEach(model.accounts) { a in
                    Button { switchAccount(a.id) } label: {
                        let off = model.accountStates[a.id]?.isConnected == false
                        let unread = model.engineUnread(accountId: a.id)
                        Label(a.displayName + (off ? " — disconnected" : unread > 0 ? " (\(unread))" : ""),
                              systemImage: a.id == model.selectedAccountId ? "checkmark" : "person.crop.circle")
                    }
                }
                Divider()
                Button { Task { await model.addAccount() } } label: { Label("Add account…", systemImage: "plus") }
            } label: {
                HStack(spacing: 8) {
                    avatar
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(detail).font(.system(size: 11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6).padding(.vertical, 5)
                .background(hovering ? MacTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .onHover { hovering = $0 }
            .accessibilityLabel("\(name). Switch account")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }

    /// The account's initial on its colour; for All accounts, the first
    /// few accounts' dots.
    @ViewBuilder private var avatar: some View {
        if let a = model.currentAccount {
            Text(String(a.displayName.prefix(1)).uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.tagForeground(a.color))
                .frame(width: 24, height: 24)
                .background(Theme.tagBackground(a.color), in: Circle())
        } else {
            HStack(spacing: -4) {
                ForEach(model.accounts.prefix(3)) { a in
                    Circle().fill(Theme.tagForeground(a.color)).frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(MacTheme.sidebar, lineWidth: 1.5))
                }
            }
            .frame(width: 24, height: 24)
            .background(MacTheme.selected, in: Circle())
        }
    }

    private func switchAccount(_ id: String?) {
        model.selectedAccountId = id
        Haptics.light()
    }
}

extension AppModel {
    /// The unified or one account's unread inbox count, read from the store
    /// (the sidebar's per-account numbers; `counts` is the selected scope's).
    func engineUnread(accountId: String?) -> Int {
        (try? engine.unreadCounts(accountId: accountId))?["inbox"] ?? 0
    }
}
