// Bundles (docs/bundles.md): the mail about one specific thing — a trip,
// an order, a project — grouped, with the model's brief (status, what is
// left to do) and the key facts first. Shared by the phone, the iPad and
// the Mac: the chip on a row, the sidebar section, the Bundles sheet, and
// "Add to bundle…" on a thread. On the phone and iPad a bundle's quiet mail
// also folds into one inbox row (`BundleFoldRow`, `AppModel.fold`).
//
// The Bundles screen covers the window on iPhone and iPad (a sheet looked
// like a dialog), presenting the shared sheets its emails' actions open
// (Remind me, Add to bundle, the composer, a summary) itself while it is
// up (`BundleSheetPresenters`, `AppModel.modal`). On the Mac the same
// stack (`BundlesStack`) is a page of the window in the list's place
// (`BundlesPage`, `WindowState.showBundles`): a sheet there looked like a
// dialog too, and an email open in it was cut off from the window's keys
// and composer. An email opens inside the stack and keeps every action
// (swipes, the long-press menu, the thread view).

import SwiftUI

/// The bundle's mark on an inbox row: its icon and name.
struct BundleChip: View {
    let bundle: BundleItem

    var body: some View {
        Chip(text: bundle.name, systemImage: bundle.category.systemImage,
             background: Theme.tagBackground(.sky), foreground: Theme.tagForeground(.sky))
            .accessibilityLabel("Bundle: \(bundle.name)")
    }
}

/// The bundle's icon on a soft tile (list rows, the folded inbox row).
struct BundleIcon: View {
    let category: BundleCategory
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: category.systemImage)
            .font(.system(size: size * 0.45, weight: .medium))
            .foregroundStyle(Theme.tagForeground(.sky))
            .frame(width: size, height: size)
            .background(Theme.tagBackground(.sky), in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
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
                        .font(.footnote)
                        .foregroundStyle(Theme.textTertiary)
                        .monospacedDigit()
                }
                Text(fold.summary)
                    .font(.footnote)
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
                        BundleScreen(bundleId: id) { path.append(.thread($0)) }
                            .backInWindowToolbar()
                    case .thread(let row):
                        ThreadView(row: row) { if !path.isEmpty { path.removeLast() } }
                            .backInWindowToolbar()
                    }
                }
                .navigationDestination(isPresented: $creating) {
                    BundleEditor(title: "New bundle") { name, category, description in
                        if let b = model.createBundle(name: name, category: category, description: description) {
                            creating = false
                            path = [.bundle(b.id)]
                        }
                    }
                }
        }
    }

    @ViewBuilder private var list: some View {
        if model.bundles.isEmpty {
            ContentUnavailableView {
                Label("No bundles yet", systemImage: "square.stack")
            } description: {
                Text("Bundles make themselves: mail about one trip, order or project is grouped as it arrives. To group something yourself, choose Add to bundle… on an email, or create one with +.")
            }
            .background(Theme.canvas)
        } else {
            List {
                if !model.activeBundles.isEmpty {
                    Section {
                        ForEach(model.activeBundles) { b in
                            NavigationLink(value: BundleRoute.bundle(b.id)) { BundleListRow(bundle: b) }
                        }
                    }
                    .menuCard()
                }
                if !model.archivedBundles.isEmpty {
                    Section("Archived") {
                        ForEach(model.archivedBundles) { b in
                            NavigationLink(value: BundleRoute.bundle(b.id)) { BundleListRow(bundle: b) }
                        }
                    }
                    .menuCard()
                }
            }
            .menuList()
            .foregroundStyle(Theme.textPrimary)
        }
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
                Text(bundle.name).font(.body.weight(.semibold)).lineLimit(1)
                Text(bundle.description.isEmpty ? meta : bundle.description)
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let at = bundle.lastActivityAt {
                Text(Formatters.rowTime(at)).font(.footnote).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
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
/// **Emails** (open first, done dimmed and folded past three; every row has
/// the inbox's swipes and menu, and ⊖: not part of this bundle) and
/// **Info** (the model's brief — where things stand, what is left to do —
/// then tracking links and key facts as plain lists).
struct BundleScreen: View {
    let bundleId: String
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
    private static let doneShownUnfolded = 3

    var body: some View {
        Group {
            if let c = contents {
                VStack(spacing: 0) {
                    Picker("Page", selection: $page) {
                        ForEach(BundlePage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    SwipePages(selection: $page, pages: BundlePage.allCases) { p in
                        switch p {
                        case .emails: emails(c)
                        case .info: info(c)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Bundle not found", systemImage: "square.stack",
                                       description: Text("It may have been deleted on another device."))
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
                BundleEditor(title: "Edit bundle", name: b.name, category: b.category, description: b.description) { name, category, description in
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
            load()
            if let c = contents, model.briefsOnOpen, model.brief(for: c) == nil { model.summarizeBundle(c) }
        }
        // Every reload re-reads the bundle: marks, removals, new links.
        .onChange(of: model.reloadCount) { _, _ in load() }
        // The brief fetched the emails' text: tracking links may be there now.
        .onChange(of: contents.flatMap { model.brief(for: $0)?.brief }) { _, _ in load() }
    }

    private func load() {
        contents = model.bundleContents(id: bundleId)
    }

    // MARK: Emails

    private func emails(_ c: BundleContents) -> some View {
        List {
            if c.bundle.isAutomatic {
                Section {
                    Label("Made automatically. Tap ⊖ on an email that doesn't belong, or rename the bundle, and it's yours.",
                          systemImage: "sparkles")
                        .font(.footnote).foregroundStyle(Theme.textTertiary)
                }
                .menuCard()
            }
            Section(c.open.isEmpty ? "Emails" : "Emails · \(c.open.count) open") {
                if c.threads.isEmpty {
                    Text("No emails yet. Choose Add to bundle… on an email; mail that shares its booking, order or tracking number follows on its own.")
                        .font(.footnote).foregroundStyle(Theme.textTertiary)
                }
                ForEach(c.open) { row in threadRow(row, dimmed: false) }
                if !c.done.isEmpty {
                    if c.done.count > Self.doneShownUnfolded {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { showDone.toggle() }
                        } label: {
                            HStack {
                                Text(showDone ? "Hide \(c.done.count) done" : "\(c.done.count) done")
                                Spacer()
                                Image(systemName: showDone ? "chevron.up" : "chevron.down").font(.footnote)
                            }
                            .foregroundStyle(Theme.textSecondary)
                        }
                        .accessibilityLabel(showDone ? "Hide \(c.done.count) done emails" : "Show \(c.done.count) done emails")
                    }
                    if showDone || c.done.count <= Self.doneShownUnfolded {
                        ForEach(c.done) { row in threadRow(row, dimmed: true) }
                    }
                }
            }
            .menuCard()
        }
        .menuList()
        .foregroundStyle(Theme.textPrimary)
    }

    /// An email as the inbox shows it — the same swipes, the same menu —
    /// plus ⊖: not part of this bundle (the model learns from it).
    private func threadRow(_ row: ThreadRow, dimmed: Bool) -> some View {
        RowSwipes.row(row, model: model) {
            HStack(spacing: 8) {
                ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil, showsBundle: false)
                    .opacity(dimmed ? 0.6 : 1)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.markRead(row)
                        openThread(row)
                    }
                Button { model.removeFromBundle(row) } label: {
                    Image(systemName: "minus.circle")
                        .font(.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Not part of this bundle")
            }
            .padding(.horizontal, 16).padding(.vertical, 7)
            .unreadEdge(!row.isRead)
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .contextMenu { RowMenu(row: row) }
    }

    // MARK: Info

    private func info(_ c: BundleContents) -> some View {
        List {
            if model.aiConfigured && !c.threads.isEmpty {
                Section {
                    BriefCard(state: model.brief(for: c)) { model.summarizeBundle(c) }
                }
                .menuCard()
            }
            if !c.bundle.description.isEmpty {
                Section {
                    Text(c.bundle.description).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                .menuCard()
            }
            if !c.links.isEmpty {
                Section("Tracking") {
                    ForEach(c.links) { l in
                        Link(destination: l.url) {
                            HStack(spacing: 8) {
                                Image(systemName: "shippingbox").font(.footnote).foregroundStyle(Theme.tagForeground(.sky))
                                Text(l.host).font(.subheadline.weight(.medium)).lineLimit(1)
                                Text(l.subject).font(.footnote).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
                .menuCard()
            }
            if !c.facts.isEmpty {
                Section("Key facts") {
                    ForEach(c.facts) { f in
                        HStack(spacing: 8) {
                            Button { open(f.threadId) } label: { FactRow(fact: f) }
                                .buttonStyle(.plain)
                            if let url = f.url {
                                Link("Track", destination: url).font(.footnote.weight(.semibold))
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
                .menuCard()
            }
            if c.links.isEmpty && c.facts.isEmpty && !(model.aiConfigured && !c.threads.isEmpty) {
                Section {
                    Text("Nothing to show yet: booking, order and tracking numbers appear here as the bundle's mail arrives.")
                        .font(.footnote).foregroundStyle(Theme.textTertiary)
                }
                .menuCard()
            }
        }
        .menuList()
        .foregroundStyle(Theme.textPrimary)
    }

    /// A fact opens the email it came from, in the sheet.
    private func open(_ threadId: String) {
        if let row = model.row(forThreadId: threadId) { openThread(row) }
    }
}

/// The model's brief on a bundle: where things stand, then what is left
/// for the user, with a refresh. Asks on a tap unless `briefsOnOpen`.
struct BriefCard: View {
    let state: BundleBriefState?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Summary", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                if state?.generating == true {
                    ProgressView().controlSize(.small)
                } else if state != nil {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise").font(.footnote) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityLabel("Summarize again")
                }
            }
            if let brief = state?.brief {
                if !brief.status.isEmpty {
                    Text(SummaryMarkup.inline(brief.status)).font(.subheadline)
                }
                if !brief.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("To do").font(.caption.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                        ForEach(brief.actions, id: \.self) { action in
                            Label {
                                Text(SummaryMarkup.inline(action)).font(.subheadline)
                            } icon: {
                                Image(systemName: "circle").font(.caption).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }
            } else if let error = state?.error {
                Text(error).font(.footnote).foregroundStyle(Theme.textTertiary)
                Button("Try again", action: refresh).font(.subheadline)
            } else if state?.generating == true {
                Text("Reading the bundle…").font(.subheadline).foregroundStyle(Theme.textTertiary)
            } else {
                Button(action: refresh) {
                    Label("Summarize status and to-dos", systemImage: "text.badge.checkmark")
                }
                .font(.subheadline)
            }
        }
        .padding(.vertical, 4)
    }
}

/// One key fact on one line: its kind, the identifier, when its email came.
struct FactRow: View {
    let fact: BundleFactItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: fact.category.systemImage)
                .font(.footnote)
                .foregroundStyle(Theme.tagForeground(.sky))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(fact.category.title).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Text(fact.value).font(.subheadline.weight(.semibold).monospaced()).lineLimit(1).textSelection(.enabled)
            Spacer(minLength: 8)
            Text(Formatters.rowTime(fact.at)).font(.footnote).foregroundStyle(Theme.textTertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the email it came from")
    }
}

/// Name, kind and the one-line description: "New bundle" and "Edit bundle".
struct BundleEditor: View {
    let title: String
    @State private var name: String
    @State private var category: BundleCategory
    @State private var description: String
    let save: (String, BundleCategory, String) -> Void

    init(title: String, name: String = "", category: BundleCategory = .other, description: String = "",
         save: @escaping (String, BundleCategory, String) -> Void) {
        self.title = title
        _name = State(initialValue: name)
        _category = State(initialValue: category)
        _description = State(initialValue: description)
        self.save = save
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            BundleFields(name: $name, category: $category, description: $description)
        }
        .menuList()
        .navigationTitle(title)
        .inlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .barTrailing) {
                Button("Save") { save(trimmed, category, description) }
                    .disabled(trimmed.isEmpty)
            }
        }
    }
}

/// The editor's fields, also inlined in the "Add to bundle" sheet.
struct BundleFields: View {
    @Binding var name: String
    @Binding var category: BundleCategory
    @Binding var description: String

    var body: some View {
        Section {
            TextField("Name, e.g. Lisbon trip", text: $name)
            Picker("Kind", selection: $category) {
                ForEach(BundleCategory.allCases) { c in
                    Label(c.title, systemImage: c.systemImage).tag(c)
                }
            }
            TextField("What it is about (optional)", text: $description, axis: .vertical)
                .lineLimit(1...3)
        } footer: {
            Text("Mail that shares a booking, order or tracking number with an email in the bundle joins it on its own.")
        }
        .menuCard()
    }
}

// MARK: - Add to bundle

/// "Add to bundle…": the likely bundle first, then the other active ones,
/// then a new one; "Remove from …" when the thread is in one.
struct AddToBundleSheet: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var name = ""
    @State private var category: BundleCategory = .other
    @State private var description = ""
    @State private var suggested: BundleItem?

    private var current: BundleItem? { model.bundle(id: row.bundleId) }
    private var others: [BundleItem] {
        model.activeBundles.filter { $0.id != suggested?.id && $0.id != row.bundleId }
    }

    var body: some View {
        List {
            Section {
                if let s = suggested {
                    pick(s, reason: "Shares a booking, order or tracking number")
                }
            } header: {
                SheetHeader(title: "Add to bundle", subtitle: row.subject.isEmpty ? row.fromSummary : row.subject) { dismiss() }
            }
            if !others.isEmpty {
                Section("Bundles") {
                    ForEach(others) { b in pick(b, reason: nil) }
                }
            }
            if creating {
                BundleFields(name: $name, category: $category, description: $description)
                Section {
                    Button {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        if model.createBundle(name: trimmed, category: category, description: description, threadIds: [row.id]) != nil {
                            dismiss()
                        }
                    } label: { Text("Create and add").frame(maxWidth: .infinity) }
                        .pillButton(prominent: true)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    Button { withAnimation { creating = true } } label: { Label("New bundle…", systemImage: "plus") }
                }
            }
            if let current {
                Section {
                    Button(role: .destructive) {
                        model.removeFromBundle(row)
                        dismiss()
                    } label: { Label("Remove from \(current.name)", systemImage: "minus.circle") }
                }
            }
        }
        .groupedListStyle()
        .scrollContentBackground(.hidden)
        .sheetSize(creating ? .large : .mediumOrLarge)
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
                    Text(b.name).foregroundStyle(Theme.textPrimary)
                    if let reason {
                        Text(reason).font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
            }
        }
    }
}
