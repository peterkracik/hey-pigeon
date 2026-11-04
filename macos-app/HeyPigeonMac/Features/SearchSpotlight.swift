// Search as Spotlight does it: `/` or the toolbar's magnifier floats a
// Liquid Glass panel in the middle of the window over the blurred list —
// a large field, the phone's From / To / Unread / account filters
// (SearchFilterBar), then the recent searches while the field is empty or
// the results as it is typed in. ↑ / ↓ walk the results, Return opens the
// highlighted thread (or, with none, leaves the results in the list), Esc
// or a click outside closes the panel. The field owns the keyboard: the
// window's shortcut map ignores keys while a text field is typing
// (WindowState.isTyping).

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
            SearchFilterBar(picking: $picking).padding(.bottom, 6)
            Hairline().opacity(0.6)
            content
        }
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
                .font(.system(size: 20))
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
                    Text("No results").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, row in
                            ResultRow(row: row, highlighted: index == highlight)
                                .id(row.id)
                                .onTapGesture { pick(row) }
                                .onHover { if $0 { highlight = index } }
                        }
                    }
                    .padding(8)
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

/// One result: the sender, the subject and the snippet, the time.
private struct ResultRow: View {
    let row: ThreadRow
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(row.fromSummary)
                .font(.system(size: 13, weight: row.isRead ? .regular : .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
            HStack(spacing: 8) {
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(.system(size: 13, weight: row.isRead ? .regular : .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Text(row.snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(Formatters.rowTime(row.lastMessageAt))
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(highlighted ? MacTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The floating shape the search and the command palette share, like
/// Spotlight's: a Liquid Glass panel near the top of the window over a
/// dimmed, blurred window (MainWindow blurs it); a click outside closes.
/// The dim reaches under the toolbar, which is transparent and empty
/// while a panel is up.
struct SpotlightPanel<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.1)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
            content()
                .frame(maxWidth: 680)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .shadow(color: .black.opacity(0.16), radius: 24, y: 10)
                .padding(.top, 40)
                .padding(.horizontal, 24)
        }
    }
}
