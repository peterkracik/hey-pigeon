// The sidebar: a grey column under the top bar — the main folders with no
// header, then "Folders" and "Labels" as small grey headers that fold
// their rows away, and at the bottom the account: its initial, its name,
// a chevron that opens the switch (All accounts, each account, Add
// account). Labels carry a pin on hover; once any is pinned, only the
// pinned ones show, with ••• for the rest (AppModel.sidebarLabels). A row only tints: on hover, and a stronger tint on the folder
// the list shows. New message, Search, Ask and Settings are the top bar's.
// The phone shows the same list as a sheet
// (Features/Sidebar/SidebarSheet); here ⌘S and the window's corner button
// slide it in and out, and a folder picked here closes the open thread.

import SwiftUI

struct SidebarColumn: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @AppStorage("sidebarFoldersOpen") private var foldersOpen = true
    @AppStorage("sidebarLabelsOpen") private var labelsOpen = true
    /// ••• under the labels: the unpinned ones too. Per Mac.
    @AppStorage("sidebarAllLabels") private var allLabels = false
    @AppStorage("sidebarBundlesOpen") private var bundlesOpen = true
    /// "N more" under the bundles: every active one, hidden ones too.
    @AppStorage("sidebarAllBundles") private var allBundles = false

    private var labels: [MailLabelItem] {
        model.labels.filter { l in
            !l.id.hasPrefix("CATEGORY_") && (model.selectedAccountId == nil || l.accountId == model.selectedAccountId)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    folder(.inbox)
                    folder(.scheduled, count: model.scheduledCount, badge: model.dueCount)
                    folder(.needReply, count: model.needReplyCount)
                    folder(.starred)
                    folder(.drafts, count: model.draftsCount)

                    // A bundle opens as a page of the window (BundlesPage), not a list view.
                    SectionHeader(title: "Bundles", open: $bundlesOpen)
                    if bundlesOpen {
                        let rows = AppModel.sidebarBundles(model.activeBundles, hidden: model.hiddenBundleIds,
                                                           expanded: allBundles)
                        ForEach(rows.shown) { b in bundleRow(b) }
                        if rows.more > 0 || allBundles && !model.hiddenBundleIds.isEmpty {
                            MoreLabelsRow(expanded: $allBundles, hidden: rows.more, noun: "bundles")
                        }
                        SidebarRow(title: model.activeBundles.isEmpty ? "Bundles" : "All bundles",
                                   systemImage: "square.stack", help: "Every bundle, archived ones too",
                                   selected: state.showBundles && state.bundlePath.isEmpty) {
                            model.openBundles()
                        }
                    }

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
                            let rows = AppModel.sidebarLabels(labels, pinned: model.pinnedLabelIds,
                                                              expanded: allLabels, current: model.currentLabelId)
                            ForEach(rows.shown) { l in
                                folder(.label(id: l.id, name: l.name), pin: l)
                            }
                            if rows.hidden > 0 || allLabels && labels.contains(where: { model.pinnedLabelIds.contains($0.id) }) {
                                MoreLabelsRow(expanded: $allLabels, hidden: rows.hidden)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            Hairline()
            AccountFooter()
        }
        .background(MacTheme.sidebar)
    }

    /// A folder row with its count; `badge` is the Scheduled row's due
    /// count, in the accent so a reminder that came due stands out.
    /// `pin`: a label row, with the pin that keeps it in the short list.
    private func folder(_ view: MailView, count: Int? = nil, badge: Int = 0, pin label: MailLabelItem? = nil) -> some View {
        let n = count ?? model.counts[view.countKey] ?? 0
        let selected = !model.isSearching && !state.searching && !state.showSettings && !state.showBundles
            && model.view == view
        return SidebarRow(title: view.title, systemImage: view.systemImage, help: view.title,
                          selected: selected, trailing: Self.badgeText(count: n, due: badge),
                          pin: label.map { l in .init(isOn: model.pinnedLabelIds.contains(l.id)) { model.togglePinned(l) } },
                          onDrop: dropAction(for: view, label: label)) {
            state.run(.go(view), in: model)
        }
    }

    /// What rows dragged onto a folder or a label do there, nil where a
    /// drop means nothing (Sent, Drafts, All emails…): a label files the
    /// thread under it and marks it done, as `v` does; Archive is Mark
    /// done, Inbox brings a done thread back, Trash deletes, Starred pins,
    /// Need reply flags.
    private func dropAction(for view: MailView, label: MailLabelItem?) -> (([String]) -> Bool)? {
        let act: ((ThreadRow) -> Void)?
        if let label {
            act = { row in
                guard row.accountId == label.accountId else {
                    model.show("\(label.name) belongs to another account")
                    return
                }
                model.move(row, to: label)
            }
        } else {
            switch view {
            case .archive: act = { if !$0.isDone { model.markDone($0) } }
            case .inbox: act = { if $0.isDone { model.markNotDone($0) } }
            case .trash: act = { model.delete($0) }
            case .starred: act = { if !$0.isPinned { model.togglePin($0) } }
            case .needReply: act = { if !$0.needsReply { model.toggleNeedsReply($0) } }
            default: act = nil
            }
        }
        guard let act else { return nil }
        return { items in dropped(items, act) }
    }

    /// Run `act` on every dropped thread; false when the drop held none.
    private func dropped(_ items: [String], _ act: (ThreadRow) -> Void) -> Bool {
        let rows = ThreadDrag.ids(in: items).compactMap { model.row(forThreadId: $0) }
        guard !rows.isEmpty else { return false }
        state.advance(in: model)
        for row in rows { act(row) }
        return true
    }

    /// A bundle with its open count; on hover the eye hides it from the
    /// short list (or shows it again), and so does the context menu.
    private func bundleRow(_ b: BundleItem) -> some View {
        let hidden = model.hiddenBundleIds.contains(b.id)
        return SidebarRow(title: b.name, systemImage: b.category.systemImage, help: b.name,
                          selected: state.showBundles && state.bundlePath.first == .bundle(b.id),
                          trailing: b.openCount > 0 ? Text("\(b.openCount)") : nil,
                          pin: .init(isOn: hidden, onSymbol: "eye.slash", offSymbol: "eye",
                                     onHelp: "Show in the sidebar", offHelp: "Hide from the sidebar") {
                              model.toggleHidden(b)
                          },
                          onDrop: { items in dropped(items) { model.addToBundle($0, bundleId: b.id) } }) {
            model.openBundles(at: b.id)
        }
        .opacity(hidden ? 0.55 : 1)
        .contextMenu {
            Button(hidden ? "Show in Sidebar" : "Hide from Sidebar") { model.toggleHidden(b) }
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
    var pin: Pin?
    /// Rows dragged from the list and dropped here (ThreadDrag); nil for
    /// a row that takes none.
    var onDrop: (([String]) -> Bool)?
    let action: () -> Void
    @State private var hovering = false
    /// A drag is over the row: it tints like the shown folder.
    @State private var targeted = false

    /// A label row's pin, shown on hover in place of the count: filled
    /// when the label is in the short list.
    struct Pin {
        let isOn: Bool
        /// The bundles reuse the slot with an eye (hide from the sidebar).
        var onSymbol = "pin.fill"
        var offSymbol = "pin"
        var onHelp = "Unpin"
        var offHelp = "Pin to the short list"
        let toggle: () -> Void
    }

    private var showsPin: Bool { pin != nil && hovering }

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
                if showsPin {
                    Color.clear.frame(width: 18, height: 1)
                } else if let trailing {
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
        // Over the row's button, so a click on the pin is the pin's.
        .overlay(alignment: .trailing) {
            if let pin, showsPin {
                Button(action: pin.toggle) {
                    Image(systemName: pin.isOn ? pin.onSymbol : pin.offSymbol)
                        .font(.system(size: 11))
                        .foregroundStyle(pin.isOn ? Theme.textSecondary : Theme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help(pin.isOn ? pin.onHelp : pin.offHelp)
                .accessibilityLabel("\(pin.isOn ? pin.onHelp : pin.offHelp): \(title)")
            }
        }
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .dropDestination(for: String.self) { items, _ in
            onDrop?(items) ?? false
        } isTargeted: { over in
            targeted = over && onDrop != nil
        }
    }

    private var background: Color {
        if selected || targeted { return MacTheme.selected }
        return hovering ? MacTheme.hover : .clear
    }
}

/// ••• under the pinned labels: opens the whole list; "Show less" folds
/// it back to the pinned ones.
private struct MoreLabelsRow: View {
    @Binding var expanded: Bool
    let hidden: Int
    /// What the row folds, for VoiceOver.
    var noun = "labels"
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: expanded ? "chevron.up" : "ellipsis")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18)
                Text(expanded ? "Show less" : "\(hidden) more")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(hovering ? MacTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(expanded ? "Show fewer \(noun)" : "Show all \(noun), \(hidden) more")
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
/// name, the unread count) as a menu that switches it.
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

        }
        // The window's corner is the sidebar button's (MainWindow).
        .padding(.leading, 50).padding(.trailing, 8).padding(.vertical, 8)
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
    /// The unified or one account's unread inbox count, from the last
    /// reload's snapshot (the sidebar's per-account numbers; `counts` is
    /// the selected scope's). It used to ask the store from inside a view
    /// body — a query on the main thread per render, and a number no
    /// reload redrew, since nothing observed it.
    func engineUnread(accountId: String?) -> Int {
        accountId.map { inboxUnread(accountId: $0) } ?? inboxUnreadAllAccounts
    }
}
