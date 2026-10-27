// "Remind me" (desktop `h`): presets, a date picker, and the follow-up
// toggle ("only if nobody replies"). Setting a reminder hides the thread
// from the inbox until then — that is also the snooze.

import SwiftUI

struct RemindSheet: View {
    let row: ThreadRow
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage("dayStartsAtHour") private var dayStart = 9
    @State private var onlyIfNoReply: Bool
    @State private var custom = Date().addingTimeInterval(86_400)
    @State private var showPicker = false

    init(row: ThreadRow) {
        self.row = row
        _onlyIfNoReply = State(initialValue: row.isFollowUp)
    }

    private var presets: [(String, Date)] {
        let cal = Calendar.current
        let now = Date()
        var out: [(String, Date)] = []
        if let evening = cal.date(bySettingHour: 18, minute: 0, second: 0, of: now), evening > now {
            out.append(("Later today", evening))
        }
        let tomorrow = cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: now)!)!
        out.append(("Tomorrow", tomorrow))
        var sat = now
        repeat { sat = cal.date(byAdding: .day, value: 1, to: sat)! } while cal.component(.weekday, from: sat) != 7
        out.append(("This weekend", cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: sat)!))
        var mon = now
        repeat { mon = cal.date(byAdding: .day, value: 1, to: mon)! } while cal.component(.weekday, from: mon) != 2
        out.append(("Next week", cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: mon)!))
        out.append(("In a month", cal.date(bySettingHour: dayStart, minute: 0, second: 0, of: cal.date(byAdding: .month, value: 1, to: now)!)!))
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text(row.subject.isEmpty ? row.fromSummary : row.subject)
                    .font(.subheadline).foregroundStyle(Theme.textTertiary).lineLimit(1)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(presets, id: \.0) { title, date in
                        presetButton(title, Formatters.reminder(date)) { set(date) }
                    }
                    presetButton("Pick date…", showPicker ? "" : "Any time") { withAnimation { showPicker.toggle() } }
                }
                if showPicker {
                    DatePicker("Remind at", selection: $custom, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                    Button { set(custom) } label: {
                        Text("Set reminder").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Toggle(isOn: $onlyIfNoReply) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only if nobody replies").font(.body.weight(.medium))
                        Text("Clears itself as soon as someone else writes in the thread.")
                            .font(.caption).foregroundStyle(Theme.textTertiary)
                    }
                }
                .tint(Theme.accent)
                if row.scheduledAt != nil {
                    Button(role: .destructive) { model.remind(row, at: nil, onlyIfNoReply: false); dismiss() } label: {
                        Label("Remove reminder", systemImage: "clock.badge.xmark").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Remind me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents(showPicker ? [.large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func presetButton(_ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func set(_ date: Date) {
        model.remind(row, at: date, onlyIfNoReply: onlyIfNoReply)
        dismiss()
    }
}
