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
// time in the mono. The phone and the iPad draw it as a grouped list
// (`menuCard`). The Mac draws the same pieces in a column of its own
// (`SheetRows.drawnByList`): its inset list ruled itself over the first
// row, under the last and under every title, beside the app's own rules,
// and cut the footer's lines in half.

import SwiftUI

struct RecentOpensView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // One set of date formatters per draw, shared by every row.
        let format = RecentOpens.Format()
        let sections = RecentOpens.sections(model.recentOpens, format: format)
        Group {
            if SheetRows.drawnByList {
                list(sections, format)
            } else {
                column(sections, format)
            }
        }
        // A sheet stands on the raised paper (a step up on dark).
        .background(Theme.raised)
        .sheetSize(.large)
        .task { await model.loadRecentOpens() }
    }

    // MARK: The phone's and the iPad's list

    private func list(_ sections: [RecentOpens.Section], _ format: RecentOpens.Format) -> some View {
        List {
            Section {
                if sections.isEmpty { emptyState.padding(.vertical, 6) }
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
                Section {} footer: { footer }
                    .listSectionSeparator(.hidden)
            }
        }
        .groupedListStyle()
        // The list's own grouped background, for the sheet's paper.
        .scrollContentBackground(.hidden)
    }

    // MARK: The Mac's column

    /// The sheet's margin on the Mac: Remind me's and Add to bundle's.
    private static let inset: CGFloat = 20

    /// The same pieces, one under the other, with nothing drawn that is
    /// not written here: the title row, each group under its title, a
    /// hairline between two rows and none over the first or under the
    /// last, the footer in full. A row is tinted under the pointer from
    /// edge to edge, as a row of the window's list is.
    private func column(_ sections: [RecentOpens.Section], _ format: RecentOpens.Format) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: RecentOpens.title) { dismiss() }
                    .padding(.top, 20)
                    .padding(.horizontal, Self.inset)
                if sections.isEmpty {
                    emptyState
                        .padding(.top, 10)
                        .padding(.horizontal, Self.inset)
                }
                ForEach(sections) { section in
                    SectionTitle(section.title)
                        // The air that parts two groups; less under the
                        // sheet's title.
                        .padding(.top, section.id == sections.first?.id ? 12 : 24)
                        .padding(.bottom, 4)
                        .padding(.horizontal, Self.inset)
                    ForEach(section.items) { item in
                        Button { model.open(item) } label: {
                            row(item, format)
                                .padding(.vertical, 9)
                                .padding(.horizontal, Self.inset)
                        }
                        .buttonStyle(.plain)
                        .threadRowHover()
                        if item.id != section.items.last?.id {
                            RowRule().padding(.horizontal, Self.inset)
                        }
                    }
                }
                if !sections.isEmpty {
                    footer
                        .padding(.top, 20)
                        .padding(.horizontal, Self.inset)
                }
            }
            .padding(.bottom, 24)
        }
        // The Mac's lists show no scroll bar.
        .scrollIndicators(.never)
    }

    // MARK: The pieces

    /// What the sheet says while there is nothing to list; nothing before
    /// the first read, when there is nothing to say yet.
    @ViewBuilder private var emptyState: some View {
        if model.recentOpensLoaded {
            let empty = RecentOpens.emptyState(available: model.readStatusAvailable,
                                               anyAccountOn: model.accounts.contains(where: \.readStatus))
            VStack(alignment: .leading, spacing: 4) {
                Text(empty.title).font(Theme.sans(.body, .medium)).foregroundStyle(Theme.textPrimary)
                Text(empty.detail).font(Theme.bodySmall).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }

    /// What the list holds and for how long, under the last group.
    private var footer: some View {
        Text(RecentOpens.footer(anyAccountOn: model.accounts.contains(where: \.readStatus)))
            .font(Theme.text(.footer)).foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
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
