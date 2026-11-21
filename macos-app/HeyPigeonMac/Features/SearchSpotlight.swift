// Search as Spotlight does it: `/` or the toolbar's magnifier floats a
// panel in the middle of the window over the dimmed list — the paper with
// an ink outline (SpotlightPanel), a large field, the phone's From / To /
// Unread / account filters (SearchFilterBar), a rule, then the
// recent searches while the field is empty or the results, ruled, as it
// is typed in. ↑ / ↓ walk the results (the highlighted one is the sunken
// grey), Return opens the highlighted thread (or, with none, leaves the
// results in the list), Esc or a click outside closes the panel. The
// field owns the keyboard: the window's shortcut map ignores keys while a
// text field is typing (WindowState.isTyping).

import SwiftUI

struct SearchSpotlight: View {
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var picking: PersonField?
    @State private var highlight = 0

    private var results: [ThreadRow] { Array(model.searchResults.prefix(60)) }

    var body: some View {
        // A click outside: the panel goes, what was typed stays in the list.
        SpotlightPanel(onClose: { leave() }) { panel }
        .sheet(item: $picking) { field in PersonPicker(field: field) }
        .onAppear { focused = true }
        .onChange(of: state.searchFocusRequest) { _, _ in focused = true }
        .onChange(of: model.searchText) { _, _ in highlight = 0 }
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            // The phone's filter bar paints the canvas behind itself; here
            // it stands on the panel's surface.
            SearchFilterBar(picking: $picking, surface: MacTheme.panel).padding(.bottom, 6)
            // What the field found is a group with no name: it opens
            // with the rule alone.
            SectionRule().padding(.horizontal, 16)
            content
            if model.isSearching {
                Hairline().padding(.horizontal, 16)
                gmailRow
            }
        }
    }

    /// The same search asked of Gmail itself: the list on this Mac holds
    /// what has been downloaded, Gmail everything (AppModel.searchGmail).
    /// The phone's row (Features/Search GmailSearchRow), in the panel's size.
    private var gmailRow: some View {
        GmailSearchRow(inPanel: true)
    }

    // MARK: The field

    private var field: some View {
        @Bindable var model = model
        return HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
            TextField("Search mail", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(Theme.sans(size: 20, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit { submit() }
                .onExitCommand { state.run(.escape, in: model) }
                .onKeyPress(.downArrow) { step(1); return .handled }
                .onKeyPress(.upArrow) { step(-1); return .handled }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 60)
    }

    // MARK: Below the field

    @ViewBuilder private var content: some View {
        if !model.isSearching {
            RecentSearches()
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .frame(height: 260)
        } else if results.isEmpty {
            Group {
                if model.isSearchPending {
                    ProgressView().controlSize(.small)
                } else {
                    Text("No matches").font(Theme.sans(size: 13)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
        } else {
            let shown = results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                            ResultRow(row: row, highlighted: index == highlight, isLast: index == shown.count - 1)
                                .id(row.id)
                                .onTapGesture { pick(row) }
                                .onHover { if $0 { highlight = index } }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 400)
                .fixedSize(horizontal: false, vertical: true)
                .onChange(of: highlight) { _, i in
                    guard results.indices.contains(i) else { return }
                    proxy.scrollTo(results[i].id)
                }
            }
        }
    }

    // MARK: Actions

    private func step(_ delta: Int) {
        guard !results.isEmpty else { return }
        highlight = min(max(highlight + delta, 0), results.count - 1)
    }

    /// Return: the highlighted thread, or the results left in the list.
    private func submit() {
        if results.indices.contains(highlight) {
            pick(results[highlight])
        } else {
            model.rememberSearch()
            leave()
        }
    }

    /// A result opens in the window; the search stays behind it, so Back
    /// lands on the results.
    private func pick(_ row: ThreadRow) {
        model.rememberSearch()
        state.searching = false
        state.open(row, in: model)
    }

    /// The panel goes; a search typed in it stays in the list (Esc there
    /// clears it).
    private func leave() {
        if model.isSearching { model.rememberSearch() }
        state.searching = false
        state.listFocusRequest += 1
    }
}

/// One result, a ruled line as in the window's list: the sender, the
/// subject and the snippet, the time in the mono. The highlighted one
/// (the arrows', the pointer's) is the sunken grey with a heavier name.
private struct ResultRow: View {
    let row: ThreadRow
    let highlighted: Bool
    /// The last result has no hairline under it.
    var isLast = false

    var body: some View {
        HStack(spacing: 12) {
            // The window's row line (MailRow's MailLineSender, MailLineSubject),
            // in the panel's narrower measures.
            MailLineSender(row: row, width: 160, heavy: highlighted)
            MailLineSubject(row: row, gap: 8)
            Spacer(minLength: 8)
            Text(Formatters.rowTime(row.lastMessageAt))
                .font(Theme.meta)
                .foregroundStyle(row.isRead ? Theme.textTertiary : Theme.textPrimary)
        }
        .padding(.horizontal, 4)
        .frame(height: MacLayout.rowHeight)
        .background(highlighted ? Theme.sunken : Color.clear)
        .overlay(alignment: .bottom) {
            if !isLast { RowRule() }
        }
        .contentShape(Rectangle())
    }
}

/// The floating shape the search and the command palette share, like
/// Spotlight's: near the top of the window, the paper with a 1 pt ink
/// outline and one shadow — the look's one outlined panel — over the
/// dimmed window; a click outside closes. The dim reaches under the
/// toolbar, which is transparent and empty while a panel is up. (It was
/// Liquid Glass over a blurred window; the paper needs neither, and the
/// window behind is no longer drawn through a blur for as long as a
/// panel is up.) The panel holds rows, never a message: a shadow would
/// fall on a web view too.
struct SpotlightPanel<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        ZStack(alignment: .top) {
            // The window behind the panel, dimmed. The dim takes the
            // click that closes the panel.
            Color.black.opacity(0.28)
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .ignoresSafeArea()
            content()
                .frame(maxWidth: 680)
                .background(MacTheme.panel, in: shape)
                .overlay(shape.strokeBorder(Theme.textPrimary, lineWidth: 1))
                .shadow(color: .black.opacity(0.22), radius: 30, y: 18)
                .padding(.top, 40)
                .padding(.horizontal, 24)
        }
    }
}
