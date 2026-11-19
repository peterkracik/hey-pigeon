// Recent Opens (docs/specs/read-status.md R7): the mail the user sent that
// was opened lately, newest first. One sheet for the phone, the iPad and
// the Mac. It shows what this device already stored — the model reads it
// once when the sheet opens and again when the store changes; nothing is
// asked of the relay for it.
//
// A row is a message: who opened it (the one recipient, by name; with
// several, nobody is named, because nobody is known), when it was last
// opened, and its subject. "Delivered to a device that hides opens" is
// not an open and is not listed here.

import SwiftUI

struct RecentOpensView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let sections = RecentOpens.sections(model.recentOpens)
        List {
            Section {
                if sections.isEmpty {
                    // Before the first read there is nothing to say yet.
                    if model.recentOpensLoaded {
                        let empty = RecentOpens.emptyState(available: model.readStatusAvailable,
                                                           anyAccountOn: model.accounts.contains(where: \.readStatus))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(empty.title).font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary)
                            Text(empty.detail).font(.subheadline).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 6)
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                SheetHeader(title: RecentOpens.title) { dismiss() }
            }
            .menuCard()
            ForEach(sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        Button { model.open(item) } label: { row(item) }
                            .buttonStyle(.plain)
                    }
                }
                .menuCard()
            }
            if !sections.isEmpty {
                Section {} footer: {
                    Text(RecentOpens.footer(anyAccountOn: model.accounts.contains(where: \.readStatus)))
                }
            }
        }
        .groupedListStyle()
        .scrollContentBackground(.hidden)
        .sheetSize(.large)
        .task { await model.loadRecentOpens() }
    }

    private func row(_ item: RecentOpenItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(RecentOpens.who(item))
                    .font(.body.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                Text(Formatters.messageTime(item.openedAt))
                    .font(Theme.meta).foregroundStyle(Theme.textTertiary).monospacedDigit()
            }
            Text(RecentOpens.subject(item))
                .font(.subheadline).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecentOpens.spoken(item))
        .accessibilityAddTraits(.isButton)
    }
}
