// Recent Opens (docs/specs/read-status.md R7): the mail the user sent that
// was opened lately, newest first. One sheet for the phone, the iPad and
// the Mac. It shows what this device already stored — the model reads it
// once when the sheet opens and again when the store changes; nothing is
// asked of the relay for it.
//
// A row is a message, on two lines: who opened it (the one recipient, by
// name; with several, nobody is named, because nobody is known) and right
// after the name when it was last opened; under them its subject. The
// rows stand under "Last 7 days", "Earlier this month" and a heading for
// each month before that. "Delivered to a device that hides opens" is
// not an open and is not listed here.
//
// The look is the menu sheets' (docs/specs/marker-look.md): the raised
// paper, each group under its title (`SectionTitle`), ruled rows, the
// time in the mono.

import SwiftUI

struct RecentOpensView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // One set of date formatters per draw, shared by every row.
        let format = RecentOpens.Format()
        let sections = RecentOpens.sections(model.recentOpens, format: format)
        List {
            Section {
                if sections.isEmpty {
                    // Before the first read there is nothing to say yet.
                    if model.recentOpensLoaded {
                        let empty = RecentOpens.emptyState(available: model.readStatusAvailable,
                                                           anyAccountOn: model.accounts.contains(where: \.readStatus))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(empty.title).font(Theme.sans(.body, .medium)).foregroundStyle(Theme.textPrimary)
                            Text(empty.detail).font(Theme.bodySmall).foregroundStyle(Theme.textSecondary)
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
                Section {
                    ForEach(section.items) { item in
                        Button { model.open(item) } label: { row(item, format) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    // The group's name as every title of a group is set:
                    // small mono capitals and a rule to the row's end.
                    SectionTitle(section.title)
                }
                .menuCard()
            }
            if !sections.isEmpty {
                Section {} footer: {
                    Text(RecentOpens.footer(anyAccountOn: model.accounts.contains(where: \.readStatus)))
                        .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                        // The whole sentence: the Mac's list cut it to one line.
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                }
                .listSectionSeparator(.hidden)
            }
        }
        .groupedListStyle()
        .scrollContentBackground(.hidden)
        // A sheet stands on the raised paper (a step up on dark); the
        // list's own grouped background is hidden just above.
        .background(Theme.raised)
        .sheetSize(.large)
        .task { await model.loadRecentOpens() }
    }

    private func row(_ item: RecentOpenItem, _ format: RecentOpens.Format) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // The time follows the name, it is not pushed to the far edge;
            // a long name gives way, the time never does. A time is data:
            // the mono.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(RecentOpens.who(item))
                    .font(Theme.sans(.body, .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(format.time(item.openedAt))
                    .font(Theme.meta).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).fixedSize().layoutPriority(1)
                Spacer(minLength: 0)
            }
            Text(RecentOpens.subject(item))
                .font(Theme.bodySmall).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(RecentOpens.spoken(item, format: format))
        .accessibilityAddTraits(.isButton)
    }
}
