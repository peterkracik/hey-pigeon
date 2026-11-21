// Bundles (docs/bundles.md): the mail about one specific thing — a trip,
// an order, a project — grouped, with the model's brief (status, what is
// left to do) and the key facts first. Shared by the phone, the iPad and
// the Mac: the bundle's mark on a row, the sidebar section, the Bundles
// screen, and "Add to bundle…" on a thread. On the phone and iPad a
// bundle's quiet mail also folds into one inbox row (`BundleFoldRow`,
// `AppModel.fold`).
//
// The Bundles screen covers the window on iPhone and iPad (a sheet looked
// like a dialog), presenting the shared sheets its emails' actions open
// (Remind me, Add to bundle, the composer, a summary) itself while it is
// up (`BundleSheetPresenters`, `AppModel.modal`). On the Mac the same
// stack (`BundlesStack`) is a page of the window in the list's place
// (`BundlesPage`, `WindowState.showBundles`): a sheet there looked like a
// dialog too, and an email open in it was cut off from the window's keys
// and composer. An email opens inside the stack and keeps every action
// (swipes, the long-press menu, the thread view). On the Mac the window
// hands the stack its own Emails page, Info page and page switcher
// (`BundleScreenParts`): the window's one-line rows and the toolbar's
// capsule tabs, where the phone's three-line rows and a segmented
// control read as another app's.
//
// The screens are drawn in the paper look (docs/specs/marker-look.md).
// Each list is the inbox's plain list on the canvas (`bundleList`): its
// rows stand straight on the paper with a hairline between them
// (`bundleRow`), and a section opens with its title (`SectionTitle`) or,
// when it has no name, with the rule alone (`SectionRule`). The titles
// are rows of the list, not its section headers: a plain list pins a
// header to its top, and the Mac floats one on a grey band.

import SwiftUI

/// The bundle's mark on an inbox row: its glyph and its name, written in
/// the mono in the sky of a state. Writing, not a chip: nothing is
/// filled behind it. (The name is from when it was one.)
struct BundleChip: View {
    let bundle: BundleItem

    var body: some View {
        StateMark(text: bundle.name, systemImage: bundle.category.systemImage, tint: Theme.state(.sky))
            .accessibilityLabel("Bundle: \(bundle.name)")
    }
}

/// The bundle's icon in a box (the list of bundles, the pickers, the
/// folded inbox row, a parcel): the glyph in the sky of a state inside a
/// hairline outline with the look's 6 pt corner. No tinted fill.
struct BundleIcon: View {
    let category: BundleCategory
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Theme.state(.sky))
            .frame(width: size, height: size)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// One folded inbox row: "Lisbon trip · 3 updates · …". Tapping it opens
/// the bundle; its swipe marks every email in it done.
struct BundleFoldRow: View {
    let fold: BundleFold

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BundleIcon(category: fold.bundle.category, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(fold.bundle.name)
                        .font(Theme.sender(false))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Formatters.rowTime(fold.newest))
                        .font(Theme.meta)
                        .foregroundStyle(Theme.textTertiary)
                }
                Text(fold.summary)
                    .font(Theme.text(.preview))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the bundle")
    }
}

// MARK: - The Bundles list

/// Where the Bundles sheet's stack goes: a bundle, or an email in one.
enum BundleRoute: Hashable {
    case bundle(String)
    case thread(ThreadRow)
}

/// What a host draws itself in the bundle view, in place of the phone's
/// pieces. The Mac window gives its own (macos-app `BundleEmails.swift`,
/// `BundleInfo.swift`): its list is the window's single-line rows with a
/// hover bar, its switchers are capsule tabs, and its Info page is titled
/// sections in a reading column. The phone and the iPad give none.
struct BundleScreenParts {
    /// The Emails · Info switcher, floating over the top of the page.
    let switcher: (Binding<BundlePage>, BundleContents) -> AnyView
    /// The Emails page.
    let emails: (BundleContents) -> AnyView
    /// The Info page.
    let info: (BundleContents) -> AnyView
}

/// The Bundles stack: active bundles, then archived ones; a bundle opens
/// its view in the same stack, and an email opens there too. The path is
/// its host's — the phone's cover (`BundlesSheet`) keeps one of its own,
/// the Mac window's page (`BundlesPage`) hands over the window's, so the
/// window knows which email is open for its keys and the composer.
struct BundlesStack: View {
    @Binding var path: [BundleRoute]
    /// What the close item does; without one there is no close item (the
    /// Mac's page closes through the window: Esc, a tab, a folder).
    var close: (() -> Void)? = nil
    /// The host's own pieces of the bundle view (the Mac window's).
    var parts: BundleScreenParts? = nil
    /// How far the list's rows and titles, and the editor's fields, stand
    /// in from the edges: the phone's 16 pt, where its mail rows start.
    /// The Mac window passes the margin of its own lists.
    var listInset: CGFloat = 16
    @Environment(AppModel.self) private var model
    @State private var creating = false

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle("Bundles")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .barLeading) {
                        Button { creating = true } label: { Image(systemName: "plus") }
                            .accessibilityLabel("New bundle")
                            .help("New bundle")
                    }
                    if let close {
                        ToolbarItem(placement: .barTrailing) {
                            Button(role: .close, action: close)
                        }
                    }
                }
                .navigationDestination(for: BundleRoute.self) { route in
                    switch route {
                    case .bundle(let id):
                        BundleScreen(bundleId: id, parts: parts, listInset: listInset) { path.append(.thread($0)) }
                            // One screen per bundle. The Mac's sidebar swaps
                            // the bundle at the same depth of the stack, and
                            // without an identity of its own the screen was
                            // kept, with the first bundle's contents: they
                            // are read when it appears.
                            .id(id)
                            .backInWindowToolbar()
                    case .thread(let row):
                        ThreadView(row: row) { if !path.isEmpty { path.removeLast() } }
                            // As the window's own thread page: another email
                            // in the same place is another thread view.
                            .id(row.id)
                            .backInWindowToolbar()
                    }
                }
                .navigationDestination(isPresented: $creating) {
                    BundleEditor(title: "New bundle", inset: listInset) { name, category, description in
                        if let b = model.createBundle(name: name, category: category, description: description) {
                            creating = false
                            path = [.bundle(b.id)]
                        }
                    }
                }
        }
    }

    @ViewBuilder private var list: some View {
        // Read once: each is a filter over every bundle.
        let active = model.activeBundles
        let archived = model.archivedBundles
        if model.bundles.isEmpty {
            ContentUnavailableView {
                BundleEmptyTitle(title: "No bundles yet", systemImage: "square.stack")
            } description: {
                Text("Bundles make themselves: mail about one trip, order or project is grouped as it arrives. To group something yourself, choose Add to bundle… on an email, or create one with +.")
                    .font(Theme.text(.bodySmall))
                    .foregroundStyle(Theme.textTertiary)
            }
            .background(Theme.canvas)
        } else {
            List {
                if !active.isEmpty {
                    // The active bundles have no title: the rule alone
                    // opens them.
                    SectionRule().bundleTitleRow(first: true, inset: listInset)
                    ForEach(active) { b in
                        NavigationLink(value: BundleRoute.bundle(b.id)) { BundleListRow(bundle: b) }
                            .bundleRow(last: b.id == active.last?.id, inset: listInset)
                    }
                }
                if !archived.isEmpty {
                    SectionTitle("Archived").bundleTitleRow(first: active.isEmpty, inset: listInset)
                    ForEach(archived) { b in
                        NavigationLink(value: BundleRoute.bundle(b.id)) { BundleListRow(bundle: b) }
                            .bundleRow(last: b.id == archived.last?.id, inset: listInset)
                    }
                }
            }
            .bundleList()
            .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// An empty state's title and symbol, as `ContentUnavailableView` takes
/// them and as the inbox's empty state draws its own (`EmptyState`): the
/// title in the display face, a little tight; the symbol standing back
/// in the tertiary grey at the size the system gives it. Both are set
/// on the text and the image themselves, where the system's own style
/// cannot replace them.
private struct BundleEmptyTitle: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            Text(title)
                .font(Theme.display(24, relativeTo: .title2))
                .tracking(-0.4)
                .foregroundStyle(Theme.textPrimary)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(Theme.textTertiary)
        }
    }
}

private extension View {
    /// A list of the Bundles screen: the inbox's plain list on the
    /// canvas. The screen is a page, not a sheet, so it stands on the
    /// canvas as the inbox does, not on the raised paper of the menu
    /// sheets (`menuList`): the mail rows in it fill themselves with the
    /// canvas, and on dark the two are a step apart. A row may be as low
    /// as its content: a title, a rule.
    func bundleList() -> some View {
        listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
    }

    /// A row of one of these lists, ruled: straight on the paper, `inset`
    /// in from the list's edges, with the hairline under it that parts
    /// it from the next row. The last row of a group has none. The
    /// hairline is the row's background, so it runs under a link's
    /// chevron too.
    func bundleRow(last: Bool = false, inset: CGFloat = 16) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
            .listRowBackground(Color.clear.overlay(alignment: .bottom) {
                if !last { RowRule().padding(.horizontal, inset) }
            })
            .listRowSeparator(.hidden)
    }

    /// A row with no hairline under it: a title, a note, a footer.
    func bundlePlainRow(inset: CGFloat = 16) -> some View {
        bundleRow(last: true, inset: inset)
    }

    /// The row of a section's title, or of the rule that opens a section
    /// without one: the air over it that parts two sections (less at the
    /// head of a list) and a little under it.
    func bundleTitleRow(first: Bool = false, inset: CGFloat = 16) -> some View {
        padding(.top, first ? 8 : 22).padding(.bottom, 4).bundlePlainRow(inset: inset)
    }

    /// A text field as the look draws one: no fill, an ink rule under it.
    func bundleField() -> some View {
        padding(.vertical, 10)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.textPrimary).frame(height: 1) }
    }
}

/// The Bundles screen as the phone and the iPad show it, covering the
/// window (`coverScreen`): the stack with a close item, presenting the
/// shared sheets itself while it is up.
struct BundlesSheet: View {
    /// A bundle to open at once (a folded row or the sidebar was tapped).
    var initialBundleId: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var path: [BundleRoute] = []

    var body: some View {
        BundlesStack(path: $path, close: { dismiss() })
            .coverContent()
            .modifier(BundleSheetPresenters())
            .onAppear {
                if let initialBundleId, path.isEmpty { path = [.bundle(initialBundleId)] }
            }
    }
}

/// The shared sheets an email's actions open, presented from the Bundles
/// sheet while it is up (the root presents them otherwise). The Mac never
/// has it up (`AppModel.showBundles` is handed to the window at once), so
/// its root presents them for the Bundles page too.
struct BundleSheetPresenters: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sharedSheets(inBundles: true)
            .sheet(item: model.modal(\.composeDraft, inBundles: true)) { draft in ComposeView(draft: draft) }
    }
}

/// A bundle in the list: icon, name, how much of it is still open.
struct BundleListRow: View {
    let bundle: BundleItem

    private var meta: String {
        let emails = bundle.threadCount == 1 ? "1 email" : "\(bundle.threadCount) emails"
        return bundle.openCount > 0 ? "\(bundle.openCount) open · \(emails)" : emails
    }

    var body: some View {
        HStack(spacing: 12) {
            BundleIcon(category: bundle.category)
            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.name)
                    .font(Theme.text(.row, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                // The counts are data and set in the mono; the user's own
                // line about the bundle is prose.
                Text(bundle.description.isEmpty ? meta : bundle.description)
                    .font(bundle.description.isEmpty ? Theme.tag : Theme.secondary)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let at = bundle.lastActivityAt {
                Text(Formatters.rowTime(at)).font(Theme.meta).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - One bundle

/// Which half of the bundle view is up.
enum BundlePage: Hashable, CaseIterable {
    case emails, info
    var title: String {
        switch self {
        case .emails: "Emails"
        case .info: "Info"
        }
    }
}

/// The bundle view, full screen, in two pages the user swipes between:
/// **Emails** (open first, done struck through and folded past three;
/// every row has the inbox's swipes and menu, and ⊖: not part of this
/// bundle) and **Info** (the model's brief — where things stand, what is
/// left to do — then tracking links and key facts as ruled rows under
/// their titles).
struct BundleScreen: View {
    let bundleId: String
    /// The host's own switcher, Emails page and Info page (the Mac
    /// window's).
    var parts: BundleScreenParts? = nil
    /// How far the editor's fields stand in from the edges
    /// (`BundlesStack.listInset`).
    var listInset: CGFloat = 16
    /// Opens an email in the sheet's stack.
    var openThread: (ThreadRow) -> Void = { _ in }
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var contents: BundleContents?
    @State private var page: BundlePage = .emails
    @State private var showDone = false
    @State private var editing = false
    @State private var confirmDelete = false

    /// Up to this many done emails show without a fold.
    static let doneShownUnfolded = 3

    var body: some View {
        Group {
            if let c = contents {
                if let parts {
                    // The host's switcher floats over the top of the page,
                    // which scrolls under it as the list does under the
                    // window's toolbar.
                    pages(c)
                        .safeAreaInset(edge: .top, spacing: 0) { parts.switcher($page, c) }
                } else {
                    VStack(spacing: 0) {
                        Picker("Page", selection: $page) {
                            ForEach(BundlePage.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        pages(c)
                    }
                }
            } else {
                ContentUnavailableView {
                    BundleEmptyTitle(title: "Bundle not found", systemImage: "square.stack")
                } description: {
                    Text("It may have been deleted on another device.")
                        .font(Theme.text(.bodySmall))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .background(Theme.canvas)
        .navigationTitle(contents?.bundle.name ?? "Bundle")
        .inlineNavigationTitle()
        .toolbar {
            if let b = contents?.bundle {
                ToolbarItem(placement: .barTrailing) {
                    Menu {
                        Button { editing = true } label: { Label("Edit", systemImage: "pencil") }
                        Button { model.setBundleArchived(b, !b.isArchived) } label: {
                            Label(b.isArchived ? "Reopen" : "Archive", systemImage: b.isArchived ? "tray.and.arrow.up" : "archivebox")
                        }
                        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete bundle", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("Bundle actions")
                }
            }
        }
        .navigationDestination(isPresented: $editing) {
            if let b = contents?.bundle {
                BundleEditor(title: "Edit bundle", name: b.name, category: b.category, description: b.description,
                             inset: listInset) { name, category, description in
                    model.updateBundle(b, name: name, category: category, description: description)
                    editing = false
                }
            }
        }
        .confirmationDialog("Delete this bundle?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete bundle", role: .destructive) {
                if let b = contents?.bundle {
                    model.deleteBundle(b)
                    dismiss()
                }
            }
        } message: {
            Text("The emails stay where they are; only the grouping goes.")
        }
        .onAppear {
            // "View details" on a parcel asked for this bundle's Info page
            // (AppModel.openParcelDetails): once, for this opening.
            if model.bundlesStartInfoId == bundleId {
                page = .info
                model.bundlesStartInfoId = nil
            }
            load()
            if let c = contents { model.summarizeBundleOnOpen(c) }
        }
        // Every reload re-reads the bundle: marks, removals, new links.
        .onChange(of: model.reloadCount) { _, _ in load() }
        // The brief fetched the emails' text: tracking links may be there now.
        .onChange(of: contents.flatMap { model.brief(for: $0)?.brief }) { _, _ in load() }
    }

    private func load() {
        contents = model.bundleContents(id: bundleId)
    }

    /// The two pages; Emails is the host's own where it has one.
    private func pages(_ c: BundleContents) -> some View {
        SwipePages(selection: $page, pages: BundlePage.allCases) { p in
            switch p {
            case .emails:
                if let parts { parts.emails(c) } else { emails(c) }
            case .info:
                if let parts { parts.info(c) } else { info(c) }
            }
        }
    }

    // MARK: Emails

    private func emails(_ c: BundleContents) -> some View {
        // Read once: each is a filter over the bundle's threads.
        let openRows = c.open
        let doneRows = c.done
        // Past three, the done emails fold behind a row that opens them.
        let folds = doneRows.count > Self.doneShownUnfolded
        // The title's count: how many are still open, when any are.
        let openCount: String? = openRows.isEmpty ? nil : "\(openRows.count) open"
        return List {
            if c.bundle.isAutomatic {
                // A section with no name: the rule alone opens it.
                SectionRule().bundleTitleRow(first: true)
                Label {
                    Text("Made automatically. Tap ⊖ on an email that doesn't belong, or rename the bundle, and it's yours.")
                        .font(Theme.text(.footer))
                        .foregroundStyle(Theme.textTertiary)
                } icon: {
                    Image(systemName: "sparkles").font(.footnote).foregroundStyle(Theme.pinkInk)
                }
                .padding(.vertical, 8)
                .bundlePlainRow()
            }
            SectionTitle("Emails", count: openCount)
                .bundleTitleRow(first: !c.bundle.isAutomatic)
            if c.threads.isEmpty {
                Text("No emails yet. Choose Add to bundle… on an email; mail that shares its booking, order or tracking number follows on its own.")
                    .font(Theme.text(.footer))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
                    .bundlePlainRow()
            }
            ForEach(openRows) { row in
                threadRow(row, last: doneRows.isEmpty && row.id == openRows.last?.id)
            }
            if folds {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showDone.toggle() }
                } label: {
                    HStack {
                        Text(showDone ? "Hide \(doneRows.count) done" : "\(doneRows.count) done")
                            .font(Theme.text(.preview, .medium))
                        Spacer()
                        Image(systemName: showDone ? "chevron.up" : "chevron.down").font(.footnote)
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(showDone ? "Hide \(doneRows.count) done emails" : "Show \(doneRows.count) done emails")
                .bundleRow(last: !showDone)
            }
            if !doneRows.isEmpty && (showDone || !folds) {
                ForEach(doneRows) { row in
                    threadRow(row, last: row.id == doneRows.last?.id)
                }
            }
        }
        .bundleList()
        .foregroundStyle(Theme.textPrimary)
    }

    /// An email as the inbox shows it — the same swipes, the same menu —
    /// plus ⊖: not part of this bundle (the model learns from it). A done
    /// one steps back to the tertiary grey with its subject and preview
    /// struck through; the row does that itself for a done email shown
    /// without its bundle's mark (`ThreadRowView`), so nothing dims it
    /// from here. The row is ruled as the inbox's are (`ThreadList`):
    /// 16 pt in, 12 above and below with the row's own 2, and the
    /// hairline under it part of the row, so it slides with it under a
    /// swipe.
    private func threadRow(_ row: ThreadRow, last: Bool) -> some View {
        RowSwipes.row(row, model: model) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil, showsBundle: false)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.markRead(row)
                            openThread(row)
                        }
                    Button { model.removeFromBundle(row) } label: {
                        Image(systemName: "minus.circle")
                            .font(.body)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 32, height: 44, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Not part of this bundle")
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .unreadCorner(!row.isRead && !row.isDone)
                if !last { RowRule() }
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .contextMenu { RowMenu(row: row) }
    }

    // MARK: Info

    private func info(_ c: BundleContents) -> some View {
        let hasBrief = model.aiConfigured && !c.threads.isEmpty
        let hasNote = !c.bundle.description.isEmpty
        return List {
            if hasBrief {
                BriefCard(state: model.brief(for: c)) { model.summarizeBundle(c) }
                    .padding(.top, 2).padding(.bottom, 4)
                    .bundlePlainRow()
            }
            if hasNote {
                // The user's own line about the bundle: a section with no
                // name, which the rule alone opens.
                SectionRule().bundleTitleRow(first: !hasBrief)
                Text(c.bundle.description)
                    .font(Theme.sans(.subheadline))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 8)
                    .bundlePlainRow()
            }
            if !c.links.isEmpty {
                SectionTitle("Tracking").bundleTitleRow(first: !hasBrief && !hasNote)
                ForEach(c.links) { l in
                    trackingRow(l).bundleRow(last: l.id == c.links.last?.id)
                }
            }
            if !c.facts.isEmpty {
                SectionTitle("Key facts").bundleTitleRow(first: !hasBrief && !hasNote && c.links.isEmpty)
                ForEach(c.facts) { f in
                    factRow(f).bundleRow(last: f.id == c.facts.last?.id)
                }
            }
            if c.links.isEmpty && c.facts.isEmpty && !hasBrief {
                SectionRule().bundleTitleRow(first: !hasNote)
                Text("Nothing to show yet: booking, order and tracking numbers appear here as the bundle's mail arrives.")
                    .font(Theme.text(.footer))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.vertical, 8)
                    .bundlePlainRow()
            }
        }
        .bundleList()
        .foregroundStyle(Theme.textPrimary)
    }

    /// One tracking link: the host it opens, the subject of the email it
    /// came from, and the arrow of a link that leaves the app.
    private func trackingRow(_ l: BundleLinkItem) -> some View {
        Link(destination: l.url) {
            HStack(spacing: 8) {
                Image(systemName: "shippingbox").font(.footnote).foregroundStyle(Theme.state(.sky))
                Text(l.host).font(Theme.sans(.subheadline, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(l.subject).font(Theme.sans(.footnote)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Theme.textTertiary)
            }
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
    }

    /// One key fact, and Track beside it when the fact has a page to
    /// follow: plain ink text, not a second filled button.
    private func factRow(_ f: BundleFactItem) -> some View {
        HStack(spacing: 8) {
            Button { open(f.threadId) } label: { FactRow(fact: f) }
                .buttonStyle(.plain)
            if let url = f.url {
                Link("Track", destination: url)
                    .font(Theme.sans(.footnote, .semibold))
                    .tint(Theme.textPrimary)
            }
        }
        .frame(minHeight: 46)
    }

    /// A fact opens the email it came from, in the sheet.
    private func open(_ threadId: String) {
        if let row = model.row(forThreadId: threadId) { openThread(row) }
    }
}

/// The model's brief on a bundle: where things stand, then what is left
/// for the user, with a refresh. Asks on a tap, or on open
/// when `AppModel.summarizeBundleOnOpen` may. It opens as every block the
/// AI wrote does: the sparkle in pink ink before the title, and Summarize
/// again after the title's rule. (The name is from when it was a card.)
struct BriefCard: View {
    let state: BundleBriefState?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Summary", systemImage: "sparkles") { control }
            if let brief = state?.brief {
                if !brief.status.isEmpty {
                    Text(SummaryMarkup.inline(brief.status))
                        .font(Theme.sans(.subheadline))
                        .foregroundStyle(Theme.textPrimary)
                }
                if !brief.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("To do")
                            .font(Theme.label)
                            .tracking(Theme.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textTertiary)
                        ForEach(brief.actions, id: \.self) { action in
                            Label {
                                Text(SummaryMarkup.inline(action))
                                    .font(Theme.sans(.subheadline))
                                    .foregroundStyle(Theme.textPrimary)
                            } icon: {
                                // What the AI says is left to do: its pink ink.
                                Image(systemName: "circle").font(.caption).foregroundStyle(Theme.pinkInk)
                            }
                        }
                    }
                }
            } else if let error = state?.error {
                Text(error).font(Theme.sans(.footnote)).foregroundStyle(Theme.dangerText)
                Button("Try again", action: refresh).font(Theme.sans(.subheadline, .semibold))
            } else if state?.generating == true {
                Text("Reading the bundle…").font(Theme.sans(.subheadline)).foregroundStyle(Theme.textTertiary)
            } else {
                Button(action: refresh) {
                    Label("Summarize status and to-dos", systemImage: "text.badge.checkmark")
                }
                .font(Theme.sans(.subheadline, .medium))
            }
        }
    }

    /// After the title's rule: the model at work, or the way to ask it
    /// again. Something to press, so it keeps its own strength beside
    /// the light grey title.
    @ViewBuilder private var control: some View {
        if state?.generating == true {
            ProgressView().controlSize(.small)
        } else if state != nil {
            Button(action: refresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.footnote)
                    .tapArea(horizontal: 12, vertical: 14)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textTertiary)
            .accessibilityLabel("Summarize again")
        }
    }
}

/// One key fact on one line: its kind, the identifier, when its email
/// came. The identifier (an order or a tracking number) and the time are
/// data, and set in the mono.
struct FactRow: View {
    let fact: BundleFactItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: fact.category.systemImage)
                .font(.footnote)
                .foregroundStyle(Theme.state(.sky))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(fact.category.title).font(Theme.sans(.subheadline)).foregroundStyle(Theme.textSecondary)
            Text(fact.value)
                .font(Theme.mono(.caption, .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(Formatters.rowTime(fact.at)).font(Theme.meta).foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the email it came from")
    }
}

/// Name, kind and the one-line description: "New bundle" and "Edit bundle".
struct BundleEditor: View {
    let title: String
    /// How far the fields stand in from the edges: the list's own measure.
    let inset: CGFloat
    @State private var name: String
    @State private var category: BundleCategory
    @State private var description: String
    let save: (String, BundleCategory, String) -> Void

    init(title: String, name: String = "", category: BundleCategory = .other, description: String = "",
         inset: CGFloat = 16, save: @escaping (String, BundleCategory, String) -> Void) {
        self.title = title
        self.inset = inset
        _name = State(initialValue: name)
        _category = State(initialValue: category)
        _description = State(initialValue: description)
        self.save = save
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            // The fields have no title: the rule alone opens them.
            SectionRule().bundleTitleRow(first: true, inset: inset)
            BundleFields(name: $name, category: $category, description: $description, inset: inset)
        }
        .bundleList()
        .navigationTitle(title)
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .barTrailing) {
                // A navigation bar's item is the system's to draw: its
                // words in the app's ink (the root's tint), as the design
                // has it. An ink capsule here would sit inside the bar's
                // own glass.
                Button("Save") { save(trimmed, category, description) }
                    .disabled(trimmed.isEmpty)
            }
        }
    }
}

/// The editor's fields, also inlined in the "Add to bundle" sheet: rows
/// of the list they are put in, `inset` in from its edges. A field has
/// no fill, only an ink rule under it; the kind is a ruled row between
/// the two, and the note about what joins the bundle ends them.
struct BundleFields: View {
    @Binding var name: String
    @Binding var category: BundleCategory
    @Binding var description: String
    var inset: CGFloat = 16

    var body: some View {
        Group {
            TextField("Name, e.g. Lisbon trip", text: $name)
                .font(Theme.text(.row, .medium))
                .borderlessFields()
                .bundleField()
                .padding(.bottom, 8)
                .bundlePlainRow(inset: inset)
            Picker(selection: $category) {
                ForEach(BundleCategory.allCases) { c in
                    Label(c.title, systemImage: c.systemImage).tag(c)
                }
            } label: {
                Text("Kind").font(Theme.text(.row, .medium))
            }
            .tint(Theme.textTertiary)
            .frame(minHeight: 46)
            .bundleRow(inset: inset)
            TextField("What it is about (optional)", text: $description, axis: .vertical)
                .lineLimit(1...3)
                .font(Theme.text(.row))
                .borderlessFields()
                .bundleField()
                .padding(.bottom, 8)
                .bundlePlainRow(inset: inset)
            Text("Mail that shares a booking, order or tracking number with an email in the bundle joins it on its own.")
                .font(Theme.text(.footer))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 8)
                .bundlePlainRow(inset: inset)
        }
    }
}

// MARK: - Add to bundle

/// "Add to bundle…": the likely bundle first, then the other active ones,
/// then a new one; "Remove from …" when the thread is in one. A sheet of
/// ruled rows under its title; Create and add is its one ink action, and
/// removing is coral text, not a fill.
struct AddToBundleSheet: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var category: BundleCategory = .other
    @State private var description = ""
    @State private var suggested: BundleItem?

    /// How far the sheet's rows stand in from its edges.
    private static let inset: CGFloat = 20

    private var current: BundleItem? { model.bundle(id: row.bundleId) }
    private var others: [BundleItem] {
        model.activeBundles.filter { $0.id != suggested?.id && $0.id != row.bundleId }
    }

    var body: some View {
        // Read once: a filter over every bundle.
        let rest = others
        List {
            // The title is the list's first row and scrolls with it; a
            // plain list would pin a section's header to the top.
            SheetHeader(title: "Add to bundle", subtitle: row.subject.isEmpty ? row.fromSummary : row.subject) { dismiss() }
                .padding(.top, 24)
                .bundlePlainRow(inset: Self.inset)
            if let s = suggested {
                pick(s, reason: "Shares a booking, order or tracking number")
                    .bundlePlainRow(inset: Self.inset)
            }
            if !rest.isEmpty {
                SectionTitle("Bundles").bundleTitleRow(inset: Self.inset)
                ForEach(rest) { b in
                    pick(b, reason: nil)
                        .bundleRow(last: b.id == rest.last?.id, inset: Self.inset)
                }
            }
            // A new bundle has no title: the rule alone opens it.
            SectionRule().bundleTitleRow(inset: Self.inset)
            if creating {
                BundleFields(name: $name, category: $category, description: $description, inset: Self.inset)
                Button {
                    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    if model.createBundle(name: trimmed, category: category, description: description, threadIds: [row.id]) != nil {
                        dismiss()
                    }
                } label: {
                    Text("Create and add")
                        .font(Theme.text(.bodySmall, .semibold))
                        .foregroundStyle(Theme.onPrimary)
                        .frame(maxWidth: .infinity)
                }
                .pillButton(prominent: true)
                .tint(Theme.textPrimary)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.top, 14)
                .bundlePlainRow(inset: Self.inset)
            } else {
                Button { withAnimation { creating = true } } label: {
                    Label("New bundle…", systemImage: "plus")
                        .font(Theme.text(.row, .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .bundlePlainRow(inset: Self.inset)
            }
            if let current {
                SectionRule().bundleTitleRow(inset: Self.inset)
                Button(role: .destructive) {
                    model.removeFromBundle(row)
                    dismiss()
                } label: {
                    Label("Remove from \(current.name)", systemImage: "minus.circle")
                        .font(Theme.text(.row, .medium))
                        .foregroundStyle(Theme.dangerText)
                        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .bundlePlainRow(inset: Self.inset)
            }
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .sheetSize(creating ? .large : .mediumOrLarge)
        // A sheet stands on the raised paper.
        .background(Theme.raised)
        .onAppear {
            suggested = model.suggestedBundle(for: row)
            // Nothing to pick from: straight to the new bundle's fields.
            if suggested == nil && others.isEmpty { creating = true }
        }
    }

    private func pick(_ b: BundleItem, reason: String?) -> some View {
        Button {
            model.addToBundle(row, bundleId: b.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                BundleIcon(category: b.category, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.name).font(Theme.text(.row, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if let reason {
                        Text(reason).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
            .contentShape(Rectangle())
        }
    }
}
