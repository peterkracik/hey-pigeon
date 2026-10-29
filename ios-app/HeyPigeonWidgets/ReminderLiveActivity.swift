// A reminder that has come due, on the Lock Screen and in the Dynamic
// Island: the thread, Done · Snooze 1 h, tap to open. The app starts it when
// it is in front and a reminder is due (ReminderLiveActivityController) and
// ends it when none is; the buttons run in the app's process.

import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct ReminderLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReminderActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.6))
                .activitySystemActionForegroundColor(.white)
                .widgetURL(AppGroup.Link.thread(context.state.threadId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isFollowUp ? "clock.arrow.circlepath" : "clock")
                        .font(.title2).foregroundStyle(WidgetPalette.reminder)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.dueCount > 1 {
                        Text("\(context.state.dueCount) due").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.from).font(.headline).lineLimit(1)
                        Text(context.state.subject).font(.subheadline).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Buttons(state: context.state)
                }
            } compactLeading: {
                Image(systemName: context.state.isFollowUp ? "clock.arrow.circlepath" : "clock")
                    .foregroundStyle(WidgetPalette.reminder)
            } compactTrailing: {
                Text(context.state.dueCount > 1 ? "\(context.state.dueCount)" : "Due")
                    .font(.caption.weight(.semibold)).monospacedDigit()
            } minimal: {
                Image(systemName: "clock.badge.exclamationmark").foregroundStyle(WidgetPalette.reminder)
            }
            .widgetURL(AppGroup.Link.thread(context.state.threadId))
            .keylineTint(WidgetPalette.reminder)
        }
    }
}

private struct LockScreenView: View {
    let state: ReminderActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.isFollowUp ? "No reply yet" : "Reminder", systemImage: state.isFollowUp ? "clock.arrow.circlepath" : "clock")
                    .font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.reminder)
                Spacer()
                if state.dueCount > 1 { Text("+\(state.dueCount - 1) more").font(.caption).foregroundStyle(.secondary) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.from).font(.headline).lineLimit(1)
                Text(state.subject.isEmpty ? "(no subject)" : state.subject).font(.subheadline).lineLimit(2)
            }
            Buttons(state: state)
        }
        .padding()
    }
}

private struct Buttons: View {
    let state: ReminderActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 10) {
            Button(intent: WidgetMarkDoneIntent(threadId: state.threadId)) {
                Label("Done", systemImage: "checkmark").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).tint(WidgetPalette.accent)
            Button(intent: WidgetSnoozeIntent(threadId: state.threadId)) {
                Label("1 h", systemImage: "zzz").font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            Spacer()
        }
    }
}
