// Search. On the phone the field hides above each list and is pulled down
// (MailListScreen, `pullDownSearch`); it holds only the words. The filters
// are boxed chips along the top — From, To, Unread and the account — that
// the model turns into the core's operators. With nothing typed the screen
// lists recent searches. Results use the inbox's rows and gestures, with
// the matching words underlined in ink. The iPad's columns (PadSearchList)
// and the Mac's panel show the same pieces.

import SwiftUI

/// What the phone's list screen shows while the search is up: the filter
/// buttons, then the recent searches or the results, and Gmail's own
/// search under them. The field itself is the list screen's, and a result
/// is pushed on its stack (`path`).
struct SearchPane: View {
    @Binding var path: [ThreadRow]
    @Environment(AppModel.self) private var model
    @State private var picking: PersonField?

    var body: some View {
        Group {
            if model.isSearching && model.groupedRows.isEmpty && model.isSearchPending {
                Color.clear
            } else if model.isSearching && model.groupedRows.isEmpty {
                VStack(spacing: 0) {
                    EmptyState(view: model.view, searching: true, lastSyncAt: model.lastSyncAt)
                    GmailSearchRow()
                }
            } else if model.isSearching {
                VStack(spacing: 0) {
                    ResultCount(count: model.searchResults.count)
                    ThreadList(path: $path)
                    GmailSearchRow()
                }
            } else {
                RecentSearches()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .safeAreaInset(edge: .top, spacing: 0) { SearchFilterBar(picking: $picking) }
        // A result opened: the search is one to remember.
        .onChange(of: path) { _, p in
            guard !p.isEmpty else { return }
            Keyboard.dismiss()
            model.rememberSearch()
        }
        .sheet(item: $picking) { field in PersonPicker(field: field) }
    }
}

/// "Search all of Gmail" under the results: the search on this device
/// covers the mail it has downloaded; Gmail's own covers everything
/// (AppModel.searchGmail). What it finds joins the results.
struct GmailSearchRow: View {
    /// In the Mac's search panel: its 36 pt line in the panel's 12 pt
    /// type, on the panel's own surface and under the panel's own rule.
    /// Elsewhere the phone's row on the canvas, parted from the results
    /// over it by a hairline as far in as theirs. One row and one wording
    /// for both; each keeps its own size.
    var inPanel = false
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { Task { await model.searchGmail() } } label: {
            HStack(spacing: 8) {
                if model.isSearchingGmail {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "tray.and.arrow.down").font(Theme.glyph(inPanel ? .caption : .bodySmall, .medium))
                }
                Text(model.isSearchingGmail ? "Asking Gmail…" : "Search all of Gmail")
                    .font(inPanel ? Theme.sans(size: 12, weight: .medium) : Theme.sans(.footnote, .semibold))
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, inPanel ? 20 : 16)
            .padding(.vertical, inPanel ? 0 : 12)
            .frame(height: inPanel ? 36 : nil)
            .frame(minHeight: inPanel ? nil : 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isSearchingGmail)
        .background(inPanel ? Color.clear : Theme.canvas)
        .overlay(alignment: .top) {
            if !inPanel { RowRule().padding(.horizontal, 16) }
        }
        // The pointer's tooltip and VoiceOver's hint say the same thing.
        .help("Finds older mail that is not on this \(Device.name) yet")
        .accessibilityHint("Finds older mail that is not on this \(Device.name) yet")
    }
}

/// "3 results" over the list, in the mono as every count is; the core
/// returns at most `AppModel.searchLimit`. Internal, like the filter bar,
/// the picker and the recent list below: the Mac's list column shows the
/// same pieces.
struct ResultCount: View {
    let count: Int

    var body: some View {
        HStack {
            Text(count >= AppModel.searchLimit ? "\(AppModel.searchLimit)+ results" : count == 1 ? "1 result" : "\(count) results")
                .font(Theme.meta)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

// MARK: Filters

/// Which person filter the picker sets.
enum PersonField: String, Identifiable {
    case from, to
    var id: Self { self }
    var title: String { self == .from ? "From" : "To" }
}

/// The row of filter buttons, each a boxed chip (docs/specs/marker-look.md,
/// R7). Off: an outline around ink words, with a chevron where it opens
/// something. On: an ink fill showing the value in the paper's colour,
/// with an × to remove it.
struct SearchFilterBar: View {
    @Binding var picking: PersonField?
    /// What the bar paints behind itself. On the phone the results scroll
    /// under it, so it is opaque: the canvas, unless the host stands on
    /// another surface (a panel) and names it.
    var surface: Color = Theme.canvas
    /// The chips scroll sideways where they may not fit (the phone). The
    /// Mac's panel and window are wide enough, and a scroll view there
    /// brought the system's soft edge with it: a haze around the chips.
    var scrolls = true
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if scrolls {
                ScrollView(.horizontal, showsIndicators: false) { chips }
            } else {
                chips.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(surface)
        .animation(.easeOut(duration: 0.15), value: model.searchFilters)
    }

    private var chips: some View {
        @Bindable var model = model
        return HStack(spacing: 6) {
                person(.from, model.searchFilters.from)
                person(.to, model.searchFilters.to)
                Button {
                    model.searchFilters.unreadOnly.toggle()
                    Haptics.light()
                } label: {
                    FilterPillLabel(title: "Unread", isOn: model.searchFilters.unreadOnly)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.searchFilters.unreadOnly ? .isSelected : [])
                if model.accounts.count > 1 {
                    Menu {
                        Picker("Account", selection: $model.searchFilters.accountId) {
                            Text("All accounts").tag(String?.none)
                            ForEach(model.accounts) { a in
                                Text(a.displayName).tag(String?.some(a.id))
                            }
                        }
                    } label: {
                        let account = model.accounts.first { $0.id == model.searchFilters.accountId }
                        // The dot stands on the chip's ink fill, which is
                        // dark on light and light on dark: the tag's own
                        // colour reads on both, its lighter pair would not.
                        FilterPillLabel(
                            title: account?.displayName ?? "All accounts",
                            isOn: account != nil,
                            dot: account.map { Theme.tagForeground($0.color) },
                            chevron: true
                        )
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .accessibilityLabel("Account")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }

    /// From / To: opens the picker; when set, shows the name and an ×.
    private func person(_ field: PersonField, _ value: SearchPerson?) -> some View {
        HStack(spacing: 0) {
            Button { picking = field } label: {
                FilterPillLabel(title: value?.name ?? field.title, isOn: value != nil, chevron: value == nil,
                                trailingPadding: value == nil ? 10 : 4)
            }
            .accessibilityLabel(value.map { "\(field.title) \($0.name)" } ?? field.title)
            if value != nil {
                Button {
                    if field == .from { model.searchFilters.from = nil } else { model.searchFilters.to = nil }
                    Haptics.light()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.onPrimary.opacity(0.75))
                        .padding(.leading, 4).padding(.trailing, 10)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(field.title.lowercased()) filter")
            }
        }
        .buttonStyle(.plain)
        .background { FilterBox(isOn: value != nil) }
    }
}

/// A filter's box, 6 pt at the corners: an outline while the filter is
/// off, an ink fill once it is on (a filter is boxed, and selection is
/// ink).
private struct FilterBox: View {
    let isOn: Bool

    var body: some View {
        let box = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if isOn {
            box.fill(Theme.textPrimary)
        } else {
            box.strokeBorder(Theme.outline, lineWidth: 1)
        }
    }
}

/// The look of one filter button; the box is drawn here unless the
/// caller draws it around more than the label (From / To with the ×).
private struct FilterPillLabel: View {
    let title: String
    let isOn: Bool
    var dot: Color? = nil
    var chevron = false
    var trailingPadding: CGFloat? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(title).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isOn ? Theme.onPrimary.opacity(0.75) : Theme.textTertiary)
            }
        }
        .font(Theme.text(.preview, .medium))
        .foregroundStyle(isOn ? Theme.onPrimary : Theme.textPrimary)
        .padding(.leading, 10)
        .padding(.trailing, trailingPadding ?? 10)
        // At least, not exactly: the title grows with the text size.
        .frame(minHeight: 32)
        .background {
            if trailingPadding == nil { FilterBox(isOn: isOn) }
        }
        .contentShape(Rectangle())
    }
}

// MARK: From / To picker

/// A short sheet of the people the mail comes from; the field narrows it
/// by name or address, and "From “…”" takes whatever was typed. Its rows
/// stand on the sheet's paper, ruled, under their title.
struct PersonPicker: View {
    let field: PersonField
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var people: [PersonSuggestion] = []

    private var current: SearchPerson? {
        field == .from ? model.searchFilters.from : model.searchFilters.to
    }

    private var typed: String { query.trimmingCharacters(in: .whitespaces) }

    private var matches: [PersonSuggestion] {
        let q = typed.lowercased()
        guard !q.isEmpty else { return Array(people.prefix(8)) }
        return people.filter { $0.person.name.lowercased().contains(q) || $0.person.address.contains(q) }
    }

    var body: some View {
        // Once per pass: every row asks which of them is the last.
        let shown = matches
        NavigationStack {
            List {
                if !typed.isEmpty && !shown.contains(where: { $0.person.address == typed.lowercased() }) {
                    Button {
                        let value = typed.filter { !$0.isWhitespace }
                        choose(SearchPerson(name: value, address: value.lowercased()))
                    } label: {
                        Label {
                            Text("\(field.title) “\(typed)”").font(Theme.sender(false))
                        } icon: {
                            Image(systemName: "magnifyingglass").font(Theme.glyph(.bodySmall))
                        }
                        .foregroundStyle(Theme.textPrimary)
                        .frame(minHeight: 46)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
                    .listRowBackground(Theme.raised)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(shown) { item in
                        Button { choose(item.person) } label: {
                            row(item)
                                .padding(.horizontal, 20)
                                .ruledBelow(item.id != shown.last?.id, inset: 20)
                                // The whole line takes the tap, margins
                                // and rule included.
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Theme.raised)
                        .listRowSeparator(.hidden)
                    }
                } header: {
                    if !shown.isEmpty {
                        // 20 pt in, as the sheet's rows are; the title
                        // stands a little further under the field than a
                        // group's does under the group before it.
                        SectionTitle(typed.isEmpty ? "Frequent" : "People")
                            .listRowInsets(EdgeInsets(top: 22, leading: 20, bottom: 4, trailing: 20))
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // A sheet: the raised paper, a step up from the canvas on dark.
            .background(Theme.raised)
            .alwaysShownSearch(text: $query, prompt: "Name or email")
            .plainInput()
            .navigationTitle(field.title)
            .inlineNavigationTitle()
            .toolbar {
                if current != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Clear") { choose(nil) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetSize(.mediumOrLarge, dragIndicator: false)
        .task { people = await model.searchPeople() }
    }

    private func row(_ item: PersonSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.person.name).font(Theme.sender(false)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(item.person.address)
                    .font(Theme.text(.secondary))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let owner = account(of: item) {
                Circle().fill(Theme.state(owner.color)).frame(width: 6, height: 6).accessibilityHidden(true)
            }
            if current?.address == item.person.address {
                // The one chosen: ink, as every selection is.
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
            }
        }
        .padding(.vertical, 9)
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }

    /// With several accounts, the one a person last wrote to: a dot in its
    /// colour at the row's end, as on the inbox's rows. Nil with one
    /// account, where there is nothing to tell apart.
    private func account(of item: PersonSuggestion) -> MailAccount? {
        guard model.accounts.count > 1 else { return nil }
        return model.accounts.first { $0.id == item.accountId }
    }

    private func choose(_ person: SearchPerson?) {
        if field == .from { model.searchFilters.from = person } else { model.searchFilters.to = person }
        Haptics.light()
        dismiss()
    }
}

// MARK: Recent

/// Nothing typed and no filter on: the last few searches, newest first,
/// ruled rows under their title; "Clear" stands at the title's end.
struct RecentSearches: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recentSearches.isEmpty {
            ContentUnavailableView {
                EmptyState.Title(title: "Search your mail", systemImage: "magnifyingglass")
            }
        } else {
            List {
                Section {
                    ForEach(model.recentSearches) { entry in
                        Button { model.runRecentSearch(entry) } label: {
                            RecentSearchRow(entry: entry)
                                .padding(.horizontal, 16)
                                .ruledBelow(entry != model.recentSearches.last)
                                // The whole line takes the tap, margins
                                // and rule included.
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        // Clear: the rows stand on what holds the list,
                        // the phone's canvas or the Mac's panel.
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button("Remove", systemImage: "trash", role: .destructive) { model.forgetSearch(entry) }
                        }
                    }
                } header: {
                    // The control is not structure: it keeps its ink.
                    SectionTitle(title: "Recent") {
                        Button { model.clearRecentSearches() } label: {
                            Text("Clear")
                                .font(Theme.text(.secondary, .semibold))
                                .foregroundStyle(Theme.textPrimary)
                                .tapArea(horizontal: 8, vertical: 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .textCase(nil)
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .dismissKeyboardOnScroll()
        }
    }
}

private struct RecentSearchRow: View {
    let entry: RecentSearch
    @Environment(AppModel.self) private var model

    /// The filters as short tags: "Priya Nair", "To Sam", "Unread", "Work".
    private var tags: [String] {
        let f = entry.filters
        var tags: [String] = []
        if let from = f.from { tags.append(from.name) }
        if let to = f.to { tags.append("To \(to.name)") }
        if f.unreadOnly { tags.append("Unread") }
        if let id = f.accountId, let a = model.accounts.first(where: { $0.id == id }) { tags.append(a.displayName) }
        return tags
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "clock")
                .font(Theme.glyph(.bodySmall))
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 6) {
                if !entry.text.isEmpty {
                    // The words in a row's own face (16 on the phone, the
                    // Mac's 13).
                    Text(entry.text).font(Theme.sender(false)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                ForEach(tags, id: \.self) { tag in FilterTag(title: tag) }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 46)
        .contentShape(Rectangle())
    }
}

/// A filter of a remembered search, drawn as the filter it was: boxed in
/// the outline grey, a size under the chips of the bar above it.
private struct FilterTag: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Theme.text(.caption, .medium))
            .foregroundStyle(Theme.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
    }
}
