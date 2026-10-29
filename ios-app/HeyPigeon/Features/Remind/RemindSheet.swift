// "Remind me" (desktop `h`): presets, a date picker, and the follow-up
// toggle ("only if nobody replies"). Setting a reminder moves the thread
// from the inbox to Scheduled until it is removed or the thread is done.
//
// A plain iOS 26 sheet: the system draws the glass background and the
// grabber; the content is a grouped list with a title row and a close
// button, no navigation bar.

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

    var body: some View {
        List {
            Section {
                ForEach(presets, id: \.0) { title, date in
                    Button { set(date) } label: {
                        LabeledContent(title, value: Formatters.reminder(date))
                    }
                    .foregroundStyle(Theme.textPrimary)
                }
                Button { withAnimation { showPicker.toggle() } } label: {
                    LabeledContent("Pick date…", value: showPicker ? "" : "Any time")
                }
                .foregroundStyle(Theme.textPrimary)
                if showPicker {
                    DatePicker("Remind at", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                    Button { set(custom) } label: { Text("Set reminder").frame(maxWidth: .infinity) }
                        .buttonStyle(.glassProminent)
                        .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remind me").font(Theme.display(22, relativeTo: .title2)).foregroundStyle(Theme.textPrimary)
                        Text(row.subject.isEmpty ? row.fromSummary : row.subject).font(.subheadline).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.glass)
                        .accessibilityLabel("Close")
                }
                .textCase(nil)
                .padding(.bottom, 6)
            }
            Section {
                Toggle(isOn: $onlyIfNoReply) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only if nobody replies")
                        Text("Clears itself as soon as someone else writes in the thread.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .tint(Theme.accent)
            }
            if row.scheduledAt != nil {
                Section {
                    Button(role: .destructive) { model.remind(row, at: nil, onlyIfNoReply: false); dismiss() } label: {
                        Label("Remove reminder", systemImage: "clock.badge.xmark")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .presentationDetents(showPicker ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func set(_ date: Date) {
        model.remind(row, at: date, onlyIfNoReply: onlyIfNoReply)
        dismiss()
    }
}
