// The sidebar: accounts (desktop 0/1/2), folders, labels, Settings — the
// desktop sidebar as a sheet, opened from the top-left circle. Same canvas
// as the main screens, sections on white cards, close in the nav bar.
// Each label has a pin; once any is pinned, the card shows only those,
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
/// closes itself; a column stays). As a column it also lists Search —
/// the split layout has no tab bar to hold it — and marks the place
/// shown among Remind me, Need reply and Search.
struct SidebarList: View {
    private let isColumn: Bool
    private let onPick: () -> Void
    @Environment(AppModel.self) private var model
    /// ••• in the labels card: the unpinned labels too. Per device.
    @AppStorage("sidebarAllLabels") private var allLabels = false
    /// "N more" in the bundles card: every active bundle, hidden ones too.
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
            if isColumn {
                Section {
                    tabRow(.search, count: 0)
                }
                .menuCard()
            }
            Section {
                folderRow(.inbox)
            }
            .menuCard()
            // Whose mail every list shows. A card of its own: in one card
            // with Inbox, the folder's checkmark and the account's sat one
            // above the other and meant different things.
            Section {
                accountRow(nil, title: "All accounts", subtitle: nil, color: nil)
                ForEach(model.accounts) { a in
                    let disconnected = model.accountStates[a.id]?.isConnected == false
                    accountRow(a.id, title: a.displayName, subtitle: a.email, color: a.color, disconnected: disconnected)
                    // The way back in, right under the account that lost
                    // its sign-in: the line used to send the user to
                    // Settings to find the same button. The sheet stays up
                    // for the consent sheet, as for Add Google account.
                    if disconnected {
                        Button {
                            Task {
                                await model.addAccount(loginHint: a.id)
                                dismiss()
                            }
                        } label: {
                            Label("Reconnect \(a.displayName)", systemImage: "arrow.clockwise")
                                .foregroundStyle(Theme.dangerText)
                        }
                    }
                }
            }
            .menuCard()
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
            Section {
                // The consent sheet needs a window to present over; closing
                // this sheet first tore it down. Stay up until it finishes.
                Button {
                    Task {
                        await model.addAccount()
                        onPick()
                    }
                } label: { Label("Add Google account", systemImage: "plus.circle") }
                Button { onPick(); model.showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
            .menuCard()
        }
        .menuList()
        .foregroundStyle(Theme.textPrimary)
        .labelDialogs($labelEditing)
    }

    private func go(_ folder: MailView) {
        model.navigate(to: .inbox, folder: folder)
        Haptics.light()
        onPick()
    }

    private func folderRow(_ view: MailView, title: String? = nil, count: Int? = nil) -> some View {
        let n = count ?? model.counts[view.countKey] ?? 0
        return Button { go(view) } label: {
            HStack {
                Label(title ?? view.title, systemImage: view.systemImage)
                Spacer()
                if n > 0 { Text("\(n)").font(.subheadline).foregroundStyle(Theme.textTertiary) }
                if model.tab == .inbox && model.folder == view {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
    }

    /// A label, with a pin on the right: pinned labels are the ones the
    /// card shows until ••• opens the rest.
    private func labelRow(_ l: MailLabelItem) -> some View {
        let view = MailView.label(id: l.id, name: l.name)
        let pinned = model.pinnedLabelIds.contains(l.id)
        return HStack {
            Button { go(view) } label: {
                HStack {
                    Label(l.name, systemImage: "tag")
                    Spacer()
                    if model.tab == .inbox && model.folder == view {
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
    }

    /// The Bundles card, right under the inboxes: the most recent ones,
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
            Text("Bundles").textCase(nil)
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
                        Text("\(b.openCount)").font(.subheadline).foregroundStyle(Theme.textTertiary)
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
        Button { model.tab = tab; onPick() } label: {
            HStack {
                Label(tab.title, systemImage: tab.systemImage)
                Spacer()
                if count > 0 { Text("\(count)").font(.subheadline).foregroundStyle(Theme.textTertiary) }
                // Beside the list there is no tab bar to say which place
                // is shown; the sheet has one behind it.
                if isColumn && model.tab == tab {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
    }

    private func accountRow(_ id: String?, title: String, subtitle: String?, color: AccountColor?, disconnected: Bool = false) -> some View {
        Button {
            model.selectedAccountId = id
            Haptics.light()
            onPick()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    // The account dot sits right in front of the name.
                    HStack(spacing: 7) {
                        if let color {
                            Circle().fill(Theme.tagForeground(color)).frame(width: 9, height: 9)
                        } else {
                            HStack(spacing: -3) {
                                ForEach(model.accounts.prefix(3)) { a in
                                    Circle().fill(Theme.tagForeground(a.color)).frame(width: 9, height: 9)
                                }
                            }
                        }
                        Text(title)
                    }
                    if disconnected {
                        Text("Disconnected — mail is not syncing").font(.caption).foregroundStyle(Theme.dangerText)
                    } else if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                Spacer()
                if id == model.selectedAccountId {
                    Image(systemName: "checkmark").font(.footnote.weight(.semibold))
                }
            }
        }
    }
}
