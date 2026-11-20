// The sidebar: accounts (desktop 0/1/2), folders, labels, Settings — the
// desktop sidebar as a sheet, opened from the top-left circle. The menu
// sheets' look (docs/specs/marker-look.md): ruled rows on the sheet's
// paper, a title only where a section has a name, close in the nav bar.
// The folder and the account on screen are the sunken rows with the
// heavier name and the checkmark; a count is in the mono.
// Each label has a pin; once any is pinned, the section shows only those,
// with ••• for the rest (AppModel.sidebarLabels, shared with the Mac).
// The list itself is `SidebarList`: the sheet shows it on the phone, and
// the iPad's split layout as its sidebar column (Features/Pad).

import SwiftUI

struct SidebarSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SidebarList { dismiss() }
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .barTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
        }
        .menuSheet()
    }
}

/// The sidebar's rows. `onPick` runs after a row was chosen (the sheet
/// closes itself; a column stays). Search is its first row: the split
/// layout has no other door to it, and on the phone it is the way in
/// that needs no gesture (the field is otherwise pulled down over a
/// list). As a column it also marks the place shown among Remind me,
/// Need reply and Search.
struct SidebarList: View {
    private let isColumn: Bool
    private let onPick: () -> Void
    @Environment(AppModel.self) private var model
    /// ••• in the labels section: the unpinned labels too. Per device.
    @AppStorage("sidebarAllLabels") private var allLabels = false
    /// "N more" in the bundles section: every active bundle, hidden ones too.
    @AppStorage("sidebarAllBundles") private var allBundles = false
    /// Gmail labels made, renamed and deleted from here (LabelDialogs).
    @State private var labelEditing = LabelEditing()

    /// The labels this sidebar lists: no Gmail categories, the account
    /// on screen (AppModel.visibleLabels, as on the Mac).
    private var labels: [MailLabelItem] {
        AppModel.visibleLabels(model.labels, accountId: model.selectedAccountId)
    }

    init(isColumn: Bool = false, onPick: @escaping () -> Void = {}) {
        self.isColumn = isColumn
        self.onPick = onPick
    }

    var body: some View {
        List {
            Section {
                tabRow(.search, count: 0)
            }
            .menuCard()
            Section {
                folderRow(.inbox)
            }
            .menuCard()
            // Whose mail every list shows. A section of its own: in one
            // section with Inbox, the folder's checkmark and the account's
            // sat one above the other and meant different things.
            Section {
                accountRow(nil, title: "All accounts", subtitle: nil, color: nil)
                ForEach(model.accounts) { a in
                    let disconnected = model.accountStates[a.id]?.isConnected == false
                    accountRow(a.id, title: a.displayName, subtitle: a.email, color: a.color, disconnected: disconnected)
                    // The way back in, right under the account that lost
                    // its sign-in: the line used to send the user to
                    // Settings to find the same button. The consent sheet
                    // needs a window to present over, and closing this sheet
                    // first tore it down: stay up until it finishes. What
                    // went wrong is the account's own line, in its colour;
                    // the way out of it is an action, so ink.
                    if disconnected {
                        Button {
                            Task {
                                await model.addAccount(loginHint: a.id)
                                onPick()
                            }
                        } label: {
                            Label("Reconnect \(a.displayName)", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            .menuCard()
            // Read status's list (docs/specs/read-status.md R7), between
            // the inboxes and the bundles: it is looked at daily, and sat
            // under every folder and label. Not in a build that cannot
            // track: the row would lead nowhere.
            if model.readStatusAvailable {
                Section {
                    Button { onPick(); model.showRecentOpens() } label: { Label(RecentOpens.title, systemImage: RecentOpens.symbol) }
                }
                .menuCard()
            }
            bundlesSection
            // The desktop sidebar's folders, in its order (Archive is "done"
            // in this app's vocabulary; Scheduled and Need reply are tabs).
            Section {
                folderRow(.starred)
                folderRow(.sent)
                folderRow(.drafts, count: model.draftsCount)
                folderRow(.archive)
                tabRow(.scheduled, count: model.scheduledCount)
                tabRow(.needReply, count: model.needReplyCount)
                folderRow(.all)
                folderRow(.spam)
                folderRow(.trash)
            }
            .menuCard()
            if !labels.isEmpty || model.labelAccountId != nil {
                let rows = AppModel.sidebarLabels(labels, pinned: model.pinnedLabelIds,
                                                  expanded: allLabels, current: model.currentLabelId)
                Section {
                    ForEach(rows.shown) { l in
                        labelRow(l)
                            // A long press: the label is the account's own
                            // in Gmail, renamed and deleted there.
                            .contextMenu {
                                Button { labelEditing.startRenaming(l) } label: { Label("Rename", systemImage: "pencil") }
                                Button(role: .destructive) { labelEditing.deleting = l } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                    if rows.hidden > 0 || allLabels && labels.contains(where: { model.pinnedLabelIds.contains($0.id) }) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { allLabels.toggle() }
                        } label: {
                            Image(systemName: allLabels ? "chevron.up" : "ellipsis")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                        }
                        .accessibilityLabel(allLabels ? "Show pinned labels only" : "Show all labels, \(rows.hidden) more")
                    }
                    Button { labelEditing.startNew() } label: { Label("New label", systemImage: "plus") }
                }
                .menuCard()
            }
            // Adding an account is in Settings › Accounts; a row for it here
            // was a second door to something done once.
            Section {
                Button { onPick(); model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            .menuCard()
        }
        .menuList()
        // A row's name is the interface face at its medium weight; the
        // row on screen asks for the heavier one itself (`rowFont`).
        .font(Theme.text(.row, .medium))
        .foregroundStyle(Theme.textPrimary)
        .labelDialogs($labelEditing)
    }

    private func go(_ folder: MailView) {
        model.navigate(to: .inbox, folder: folder)
        Haptics.light()
        onPick()
    }

    /// The name of a row: heavier on the row that is on screen (the
    /// folder, the account, a column's tab). With the sunken step under
    /// it and the checkmark, that is how the look marks a selected row
    /// (marker-look R9); the checkmark keeps it from resting on a colour.
    private static func rowFont(_ selected: Bool) -> Font {
        Theme.text(.row, selected ? .semibold : .medium)
    }

    /// What lies under a row: the sunken step for the row on screen, the
    /// sheet's paper for every other (`menuCard` clears the list's own).
    private static func rowBackground(_ selected: Bool) -> Color {
        selected ? Theme.sunken : Color.clear
    }

    private func folderRow(_ view: MailView, title: String? = nil, count: Int? = nil) -> some View {
        let n = count ?? model.counts[view.countKey] ?? 0
        let selected = model.tab == .inbox && model.folder == view
        return Button { go(view) } label: {
            HStack {
                Label(title ?? view.title, systemImage: view.systemImage)
                    .font(Self.rowFont(selected))
                Spacer()
                if n > 0 { Text("\(n)").font(Theme.meta).foregroundStyle(Theme.textTertiary) }
                if selected {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
        .listRowBackground(Self.rowBackground(selected))
    }

    /// A label, with a pin on the right: pinned labels are the ones the
    /// section shows until ••• opens the rest.
    private func labelRow(_ l: MailLabelItem) -> some View {
        let view = MailView.label(id: l.id, name: l.name)
        let pinned = model.pinnedLabelIds.contains(l.id)
        let selected = model.tab == .inbox && model.folder == view
        return HStack {
            Button { go(view) } label: {
                HStack {
                    Label(l.name, systemImage: "tag")
                        .font(Self.rowFont(selected))
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button { model.togglePinned(l) } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.footnote)
                    .foregroundStyle(pinned ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 32, height: 28)
                    .tapArea(horizontal: 6, vertical: 8)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(pinned ? "Unpin \(l.name)" : "Pin \(l.name)")
        }
        .listRowBackground(Self.rowBackground(selected))
    }

    /// The Bundles section, under the inboxes and Recent Opens: the most recent ones,
    /// "N more" for the rest (hidden ones included, to show them again),
    /// then the whole list. A bundle opens its own sheet; this one closes.
    private var bundlesSection: some View {
        let rows = AppModel.sidebarBundles(model.activeBundles, hidden: model.hiddenBundleIds, expanded: allBundles)
        return Section {
            ForEach(rows.shown) { b in bundleRow(b) }
            if rows.more > 0 || allBundles && !model.hiddenBundleIds.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { allBundles.toggle() }
                } label: {
                    Label(allBundles ? "Show less" : "\(rows.more) more",
                          systemImage: allBundles ? "chevron.up" : "ellipsis")
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel(allBundles ? "Show fewer bundles" : "Show all bundles, \(rows.more) more")
            }
            Button { model.openBundles() } label: {
                Label(model.activeBundles.isEmpty ? "Bundles" : "All bundles", systemImage: "square.stack")
            }
        } header: {
            SectionTitle("Bundles")
        }
        .menuCard()
    }

    /// A bundle, its open count, and (in the full list) the eye that hides
    /// it from the short one; the long-press menu hides it too.
    private func bundleRow(_ b: BundleItem) -> some View {
        let hidden = model.hiddenBundleIds.contains(b.id)
        return HStack {
            Button { model.openBundles(at: b.id) } label: {
                HStack {
                    Label(b.name, systemImage: b.category.systemImage)
                        .opacity(hidden ? 0.5 : 1)
                    Spacer()
                    if b.openCount > 0 {
                        Text("\(b.openCount)").font(Theme.meta).foregroundStyle(Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if allBundles {
                Button { model.toggleHidden(b) } label: {
                    Image(systemName: hidden ? "eye.slash" : "eye")
                        .font(.footnote)
                        .foregroundStyle(hidden ? Theme.textTertiary : Theme.textSecondary)
                        .frame(width: 32, height: 28)
                        .tapArea(horizontal: 6, vertical: 8)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(hidden ? "Show \(b.name) in the sidebar" : "Hide \(b.name) from the sidebar")
            }
        }
        .contextMenu {
            Button { model.toggleHidden(b) } label: {
                Label(hidden ? "Show in sidebar" : "Hide from sidebar", systemImage: hidden ? "eye" : "eye.slash")
            }
        }
    }

    private func tabRow(_ tab: MainTab, count: Int) -> some View {
        // Beside the list there is no tab bar to say which place is
        // shown; the sheet has one behind it.
        let selected = isColumn && model.tab == tab
        return Button { model.tab = tab; onPick() } label: {
            HStack {
                Label(tab.title, systemImage: tab.systemImage)
                    .font(Self.rowFont(selected))
                Spacer()
                if count > 0 { Text("\(count)").font(Theme.meta).foregroundStyle(Theme.textTertiary) }
                if selected {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
        .listRowBackground(Self.rowBackground(selected))
    }

    private func accountRow(_ id: String?, title: String, subtitle: String?, color: AccountColor?, disconnected: Bool = false) -> some View {
        let selected = id == model.selectedAccountId
        return Button {
            model.selectedAccountId = id
            Haptics.light()
            onPick()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    // The account's dot sits right in front of the name:
                    // 6 pt in the account's colour, as on a mail row.
                    HStack(spacing: 7) {
                        if let color {
                            Circle().fill(Theme.state(color)).frame(width: 6, height: 6)
                        } else {
                            HStack(spacing: -2) {
                                ForEach(model.accounts.prefix(3)) { a in
                                    Circle().fill(Theme.state(a.color)).frame(width: 6, height: 6)
                                }
                            }
                        }
                        Text(title).font(Self.rowFont(selected))
                    }
                    if disconnected {
                        Text("Disconnected — mail is not syncing").font(Theme.secondary).foregroundStyle(Theme.dangerText)
                    } else if let subtitle {
                        Text(subtitle).font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
        .listRowBackground(Self.rowBackground(selected))
    }
}
