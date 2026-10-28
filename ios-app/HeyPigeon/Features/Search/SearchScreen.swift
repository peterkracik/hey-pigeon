// The Search tab. The field (the tab bar's search slot) holds only the
// words; the filters are buttons along the top — From, To, Unread and the
// account — that the model turns into the core's operators. With nothing
// typed the screen lists recent searches. Results use the inbox's rows and
// gestures, with the matching words underlined.

import SwiftUI

struct SearchScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var path: [ThreadRow] = []
    @State private var picking: PersonField?

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            Group {
                if model.isSearching && model.groupedRows.isEmpty {
                    EmptyState(view: model.view, searching: true, lastSyncAt: model.lastSyncAt)
                } else if model.isSearching {
                    VStack(spacing: 0) {
                        ResultCount(count: model.searchResults.count)
                        ThreadList(path: $path)
                    }
                } else {
                    RecentSearches()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas)
            .safeAreaInset(edge: .top, spacing: 0) { SearchFilterBar(picking: $picking) }
            .navigationTitle("Search")
            // On the phone the field lives in the tab bar, so the empty
            // navigation bar would only push the filters down.
            .toolbarVisibility(sizeClass == .compact ? .hidden : .automatic, for: .navigationBar)
            .searchable(text: $model.searchText, prompt: "Search")
            .onSubmit(of: .search) { model.rememberSearch() }
            .navigationDestination(for: ThreadRow.self) { row in
                ThreadView(row: row) { path.removeLast() }
            }
            .onChange(of: path) { _, p in
                guard !p.isEmpty else { return }
                Keyboard.dismiss()
                model.rememberSearch()
            }
            .sheet(item: $picking) { field in PersonPicker(field: field) }
        }
    }
}

/// "3 results" over the list; the core returns at most 50.
private struct ResultCount: View {
    let count: Int

    var body: some View {
        HStack {
            Text(count >= 50 ? "50+ results" : count == 1 ? "1 result" : "\(count) results")
                .font(Theme.display(13, relativeTo: .caption))
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }
}

// MARK: Filters

enum PersonField: String, Identifiable {
    case from, to
    var id: Self { self }
    var title: String { self == .from ? "From" : "To" }
}

/// The row of filter buttons. Off: grey with a chevron. On: filled, showing
/// the value, with an × to remove it.
private struct SearchFilterBar: View {
    @Binding var picking: PersonField?
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
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
        .background(Theme.canvas)
        .animation(.easeOut(duration: 0.15), value: model.searchFilters)
    }

    /// From / To: opens the picker; when set, shows the name and an ×.
    private func person(_ field: PersonField, _ value: SearchPerson?) -> some View {
        HStack(spacing: 0) {
            Button { picking = field } label: {
                FilterPillLabel(title: value?.name ?? field.title, isOn: value != nil, chevron: value == nil,
                                trailingPadding: value == nil ? 12 : 4)
            }
            .accessibilityLabel(value.map { "\(field.title) \($0.name)" } ?? field.title)
            if value != nil {
                Button {
                    if field == .from { model.searchFilters.from = nil } else { model.searchFilters.to = nil }
                    Haptics.light()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Theme.canvas.opacity(0.7))
                        .padding(.leading, 4).padding(.trailing, 11)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(field.title.lowercased()) filter")
            }
        }
        .buttonStyle(.plain)
        .background(value != nil ? Theme.textPrimary : Theme.sunken, in: Capsule())
    }
}

/// The look of one filter button; the background is drawn here unless the
/// caller draws it around more than the label (From / To with the ×).
private struct FilterPillLabel: View {
    let title: String
    let isOn: Bool
    var dot: Color? = nil
    var chevron = false
    var trailingPadding: CGFloat? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(title).lineLimit(1)
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isOn ? Theme.canvas.opacity(0.7) : Theme.textTertiary)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(isOn ? Theme.canvas : Theme.textPrimary)
        .padding(.leading, 12)
        .padding(.trailing, trailingPadding ?? 12)
        .frame(height: 32)
        .background {
            if trailingPadding == nil {
                Capsule().fill(isOn ? Theme.textPrimary : Theme.sunken)
            }
        }
        .contentShape(Capsule())
    }
}

// MARK: From / To picker

/// A short sheet of the people the mail comes from; the field narrows it
/// by name or address, and "From “…”" takes whatever was typed.
private struct PersonPicker: View {
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
        NavigationStack {
            List {
                if !typed.isEmpty && !matches.contains(where: { $0.person.address == typed.lowercased() }) {
                    Button {
                        let value = typed.filter { !$0.isWhitespace }
                        choose(SearchPerson(name: value, address: value.lowercased()))
                    } label: {
                        Label("\(field.title) “\(typed)”", systemImage: "magnifyingglass")
                            .foregroundStyle(Theme.textPrimary)
                    }
                    .listRowBackground(Theme.canvas)
                }
                Section {
                    ForEach(matches) { item in
                        Button { choose(item.person) } label: { row(item) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.canvas)
                    }
                } header: {
                    if !matches.isEmpty {
                        Text(typed.isEmpty ? "Frequent" : "People")
                            .font(Theme.display(13, relativeTo: .caption))
                            .foregroundStyle(Theme.textTertiary)
                            .textCase(nil)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Name or email")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .navigationTitle(field.title)
            .navigationBarTitleDisplayMode(.inline)
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
        .presentationDetents([.medium, .large])
        .task { people = model.searchPeople() }
    }

    private func row(_ item: PersonSuggestion) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                name(item).font(.body.weight(.semibold)).lineLimit(1)
                Text(item.person.address)
                    .font(.footnote)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if current?.address == item.person.address {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    /// With several accounts the first letter takes the account's colour,
    /// as in the inbox rows.
    private func name(_ item: PersonSuggestion) -> Text {
        let name = item.person.name
        guard model.accounts.count > 1, let first = name.first,
              let account = model.accounts.first(where: { $0.id == item.accountId })
        else { return Text(name).foregroundStyle(Theme.textPrimary) }
        return Text(String(first)).foregroundStyle(Theme.tagForeground(account.color))
            + Text(name.dropFirst()).foregroundStyle(Theme.textPrimary)
    }

    private func choose(_ person: SearchPerson?) {
        if field == .from { model.searchFilters.from = person } else { model.searchFilters.to = person }
        Haptics.light()
        dismiss()
    }
}

// MARK: Recent

/// Nothing typed and no filter on: the last few searches, newest first.
private struct RecentSearches: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.recentSearches.isEmpty {
            ContentUnavailableView {
                Label("Search your mail", systemImage: "magnifyingglass")
                    .font(Theme.display(20, relativeTo: .title3))
            }
        } else {
            List {
                Section {
                    ForEach(model.recentSearches) { entry in
                        Button { model.runRecentSearch(entry) } label: { RecentSearchRow(entry: entry) }
                            .buttonStyle(.plain)
                            .listRowBackground(Theme.canvas)
                            .listRowSeparator(.hidden)
                            .swipeActions {
                                Button("Remove", systemImage: "trash", role: .destructive) { model.forgetSearch(entry) }
                            }
                    }
                } header: {
                    HStack {
                        Text("Recent")
                            .font(Theme.display(13, relativeTo: .caption))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Clear") { model.clearRecentSearches() }
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .textCase(nil)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.immediately)
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
                .font(.subheadline)
                .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 6) {
                if !entry.text.isEmpty {
                    Text(entry.text).foregroundStyle(Theme.textPrimary).lineLimit(1)
                }
                ForEach(tags, id: \.self) { tag in
                    Chip(text: tag, background: Theme.sunken, foreground: Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
