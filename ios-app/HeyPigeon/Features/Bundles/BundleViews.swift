// Bundles (docs/bundles.md): the mail about one specific thing — a trip,
// an order, a project — grouped, with its key facts first. Shared by the
// phone, the iPad and the Mac. Three touchpoints and nothing else: the
// chip on a row, the Bundles list (a sheet, from the sidebar), and "Add to
// bundle…" on a thread. On the phone and iPad a bundle's quiet mail also
// folds into one inbox row (`BundleFoldRow`, `AppModel.fold`).
//
// Opening an email from a bundle closes the sheet and opens it in the
// inbox (`AppModel.openThread`): a thread view inside the sheet could not
// present the remind and bundle sheets, which hang off the root.

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

/// The Bundles sheet: active bundles, then archived ones; a bundle opens
/// its view in the same stack.
struct BundlesSheet: View {
    /// A bundle to open at once (a folded row was tapped).
    var initialBundleId: String? = nil
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [String] = []
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
                    }
                    ToolbarItem(placement: .barTrailing) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .navigationDestination(for: String.self) { id in BundleScreen(bundleId: id) }
                .navigationDestination(isPresented: $creating) {
                    BundleEditor(title: "New bundle") { name, category, description in
                        if let b = model.createBundle(name: name, category: category, description: description) {
                            creating = false
                            path = [b.id]
                        }
                    }
                }
        }
        .menuSheet()
        .onAppear {
            if let initialBundleId, path.isEmpty { path = [initialBundleId] }
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
                            NavigationLink(value: b.id) { BundleListRow(bundle: b) }
                        }
                    }
                    .menuCard()
                }
                if !model.archivedBundles.isEmpty {
                    Section("Archived") {
                        ForEach(model.archivedBundles) { b in
                            NavigationLink(value: b.id) { BundleListRow(bundle: b) }
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

/// The bundle view: key facts first, then the open emails, then the done
/// ones — dimmed, and folded behind one row when there are more than three.
struct BundleScreen: View {
    let bundleId: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var contents: BundleContents?
    @State private var showDone = false
    @State private var editing = false
    @State private var confirmDelete = false

    /// Up to this many done emails show without a fold.
    private static let doneShownUnfolded = 3

    var body: some View {
        Group {
            if let c = contents {
                list(c)
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
        .onAppear(perform: load)
        // Every change to the mail re-reads the bundles (their counts), so
        // this follows marks, removals and new links.
        .onChange(of: model.bundles) { _, _ in load() }
    }

    private func load() {
        contents = model.bundleContents(id: bundleId)
    }

    private func list(_ c: BundleContents) -> some View {
        List {
            if !c.facts.isEmpty {
                Section("Key facts") {
                    ForEach(c.facts) { f in
                        Button { open(f.threadId) } label: { FactRow(fact: f) }
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .menuCard()
            }
            if !c.bundle.description.isEmpty {
                Section {
                    Text(c.bundle.description).font(.subheadline).foregroundStyle(Theme.textSecondary)
                }
                .menuCard()
            }
            if c.bundle.isAutomatic {
                Section {
                    Label("Made automatically. Remove an email that doesn't belong, or rename the bundle, and it's yours.",
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

    private func threadRow(_ row: ThreadRow, dimmed: Bool) -> some View {
        Button { open(row.id) } label: {
            ThreadRowView(row: row, showAccountDot: model.selectedAccountId == nil, showsBundle: false)
                .opacity(dimmed ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.removeFromBundle(row) } label: { Label("Remove from bundle", systemImage: "minus.circle") }
        }
    }

    /// The email opens in the inbox; the sheet goes away.
    private func open(_ threadId: String) {
        model.showBundles = false
        model.openThread(id: threadId)
    }
}

/// One key fact: what it is, the identifier, when its email came.
struct FactRow: View {
    let fact: BundleFactItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fact.category.systemImage)
                .font(.body)
                .foregroundStyle(Theme.tagForeground(.sky))
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(fact.category.title).font(.caption).foregroundStyle(Theme.textTertiary)
                Text(fact.value).font(.body.weight(.semibold).monospaced()).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Text(Formatters.rowTime(fact.at)).font(.footnote).foregroundStyle(Theme.textTertiary)
        }
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
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add to bundle").font(Theme.display(22, relativeTo: .title2)).foregroundStyle(Theme.textPrimary)
                        Text(row.subject.isEmpty ? row.fromSummary : row.subject)
                            .font(.subheadline).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Close")
                }
                .textCase(nil)
                .padding(.bottom, 6)
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
                        .buttonStyle(.glassProminent)
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
