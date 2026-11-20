// "Remind me" (desktop `h`): presets, a date picker, and the follow-up
// toggle ("only if nobody replies"). Setting a reminder moves the thread
// from the inbox to Scheduled until it is removed or the thread is done.
//
// A sheet on the raised paper (docs/specs/marker-look.md), as Add to
// bundle is: a plain list with a title row and a close button (Theme's
// SheetHeader), no navigation bar and no cards — the rows stand under
// one rule, 20 pt in from the sheet's edges, with a hairline between two
// of them and each preset's time in the mono. The follow-up switch comes
// first, then the presets, each of which sets and closes.

import SwiftUI

struct RemindSheet: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var onlyIfNoReply: Bool
    @State private var custom = Date().addingTimeInterval(86_400)
    @State private var showPicker = false

    init(row: ThreadRow) {
        self.row = row
        _onlyIfNoReply = State(initialValue: row.isFollowUp)
    }

    /// The presets as dates, from ReminderPresets (shared with the Siri
    /// intent so both land on the same minute).
    private var presets: [(String, Date)] {
        ReminderPreset.available().map { ($0.preset.title, $0.date) }
    }

    /// A row's name: a menu row's medium, 16 on the phone and 13 in the
    /// Mac's sheet. Theme has no role of its own for a menu row yet; a
    /// read sender's (`Theme.sender`) is the same face at the same sizes.
    private static let rowFont = Theme.sender(false)
    /// A preset's time: data, so the mono.
    private static let timeFont = Theme.mono(size: 13, relativeTo: .footnote)

    var body: some View {
        List {
            // The title is the list's first row and scrolls with it: a
            // plain list would pin a section's header to the top.
            SheetHeader(title: "Remind me", subtitle: row.subject.isEmpty ? row.fromSummary : row.subject) { dismiss() }
                .padding(.top, 24)
                .remindRow(ruled: false)
            // The rows are a section with no name: they open with the
            // rule alone.
            SectionRule()
                .padding(.top, 8)
                .remindRow(ruled: false)
            // First, above the presets: a preset sets the reminder and
            // closes the sheet, so the switch below them was only ever
            // seen too late.
            Toggle(isOn: $onlyIfNoReply) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Only if nobody replies").font(Self.rowFont).foregroundStyle(Theme.textPrimary)
                    Text("Clears itself as soon as someone else writes in the thread.")
                        .font(Theme.secondary).foregroundStyle(Theme.textTertiary)
                }
            }
            // A switch that is on is ink, not pink.
            .tint(Theme.switchOn)
            .padding(.vertical, 12)
            .remindRow()
            ForEach(presets, id: \.0) { title, date in
                Button { set(date) } label: {
                    presetRow(title, time: Formatters.reminder(date))
                }
                .remindRow()
            }
            Button { withAnimation { showPicker.toggle() } } label: {
                presetRow("Pick date…", time: showPicker ? "" : "Any time")
            }
            // The last row of the list, until the picker opens under it.
            .remindRow(ruled: showPicker)
            if showPicker {
                DatePicker("Remind at", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                    .remindRow(ruled: false)
                // The sheet's one ink action, once a date is being picked.
                Button { set(custom) } label: {
                    Text("Set reminder")
                        .font(Theme.text(.bodySmall, .semibold))
                        .foregroundStyle(Theme.onPrimary)
                        .frame(maxWidth: .infinity)
                }
                .pillButton(prominent: true)
                .tint(Theme.textPrimary)
                .padding(.vertical, 12)
                .remindRow(ruled: false)
            }
            if row.scheduledAt != nil {
                // Taking the reminder off stands apart, under a rule of
                // its own.
                SectionRule()
                    .padding(.top, 22)
                    .remindRow(ruled: false)
                Button(role: .destructive) { model.remind(row, at: nil, onlyIfNoReply: false); dismiss() } label: {
                    // Removing is the danger colour, as writing; said on
                    // the label, since the role's own red is the system's.
                    Label("Remove reminder", systemImage: "clock.badge.xmark")
                        .font(Self.rowFont)
                        .foregroundStyle(Theme.dangerText)
                        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .remindRow(ruled: false)
            }
        }
        .listStyle(.plain)
        // A row may be as low as its content: the rule is a row too.
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .sheetSize(showPicker ? .large : .mediumOrLarge)
        // A sheet stands on the raised paper.
        .background(Theme.raised)
    }

    /// A preset's row is this tall.
    private static let rowHeight: CGFloat = 46

    /// A preset as a ruled row: its name in ink, and its time in the mono
    /// at the row's end.
    private func presetRow(_ title: String, time: String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(Self.rowFont).foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            Text(time).font(Self.timeFont).foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func set(_ date: Date) {
        IntentDonations.reminded(row, at: date, onlyIfNoReply: onlyIfNoReply, in: model)
        model.remind(row, at: date, onlyIfNoReply: onlyIfNoReply)
        dismiss()
    }
}

private extension View {
    /// A row of the Remind sheet: straight on its paper, 20 pt in from
    /// the sheet's edges (Add to bundle's measure), with the hairline
    /// under it that parts it from the next row. What is no row (the
    /// title, a rule) and the last row of a group have none.
    func remindRow(ruled: Bool = true) -> some View {
        let inset: CGFloat = 20
        return listRowInsets(EdgeInsets(top: 0, leading: inset, bottom: 0, trailing: inset))
            .listRowBackground(Color.clear.overlay(alignment: .bottom) {
                if ruled { RowRule().padding(.horizontal, inset) }
            })
            .listRowSeparator(.hidden)
    }
}
