// The widget extension: Unread (small), Next reminder (medium), Need reply
// (medium), the reminder Live Activity and the Controls. Everything reads
// WidgetSnapshot from the App Group — the app writes it after every reload;
// buttons run WidgetMarkDoneIntent in the app's process and taps deep-link
// through heypigeon://.

import AppIntents
import SwiftUI
import WidgetKit

@main
struct HeyPigeonWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadWidget()
        NextReminderWidget()
        NeedReplyWidget()
        ReminderLiveActivity()
        ComposeControl()
        ScheduledControl()
        InboxControl()
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// One provider for every widget: the snapshot now, then again when the
/// next reminder comes due (so "Next reminder" flips to due on its own).
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: context.isPreview ? .placeholder : WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetSnapshot.load()
        let now = Date()
        var entries = [SnapshotEntry(date: now, snapshot: snapshot)]
        // The next reminder moving from "upcoming" to "due" is a change the
        // app may be asleep for: schedule an entry at that minute with the
        // row moved over.
        if let next = snapshot.upcoming.first, next.at > now {
            let moved = WidgetSnapshot(
                updatedAt: snapshot.updatedAt, lastSyncAt: snapshot.lastSyncAt, unreadTotal: snapshot.unreadTotal,
                accounts: snapshot.accounts, due: snapshot.due + [next], upcoming: Array(snapshot.upcoming.dropFirst()),
                needReply: snapshot.needReply, needReplyTotal: snapshot.needReplyTotal
            )
            entries.append(SnapshotEntry(date: next.at, snapshot: moved))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Unread

struct UnreadWidget: Widget {
    static let kind = "app.heypigeon.widget.unread"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            UnreadView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(AppGroup.Link.folder("inbox"))
        }
        .configurationDisplayName("Unread")
        .description("How much is waiting in your inbox, by account.")
        .supportedFamilies([.systemSmall, .accessoryCircular, .accessoryRectangular])
    }
}

struct UnreadView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "tray").font(.caption)
                Text("\(snapshot.unreadTotal)").font(.title3.weight(.bold)).monospacedDigit()
            }
        case .accessoryRectangular:
            HStack {
                Image(systemName: "tray")
                VStack(alignment: .leading) {
                    Text("\(snapshot.unreadTotal) unread").font(.headline)
                    Text(snapshot.accounts.map { "\($0.name) \($0.unread)" }.joined(separator: " · ")).font(.caption).lineLimit(1)
                }
            }
        default:
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "tray").foregroundStyle(.secondary)
                    Spacer()
                    Text("Inbox").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("\(snapshot.unreadTotal)")
                    .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                Text(snapshot.unreadTotal == 1 ? "unread" : "unread").font(.caption).foregroundStyle(.secondary)
                // One bar per account, in its colour, proportional to its share.
                if snapshot.accounts.count > 1, snapshot.unreadTotal > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(snapshot.accounts.filter { $0.unread > 0 }) { a in
                                Capsule().fill(WidgetPalette.account(a.color))
                                    .frame(width: max(4, geo.size.width * CGFloat(a.unread) / CGFloat(snapshot.unreadTotal) - 2))
                            }
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
    }
}

// MARK: - Next reminder

struct NextReminderWidget: Widget {
    static let kind = "app.heypigeon.widget.reminder"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NextReminderView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Next reminder")
        .description("What's due, with Done right there.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

struct NextReminderView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var row: WidgetSnapshot.Row? { snapshot.due.first ?? snapshot.upcoming.first }
    private var isDue: Bool { !snapshot.due.isEmpty }

    var body: some View {
        if let row {
            if family == .accessoryRectangular {
                VStack(alignment: .leading) {
                    Text(isDue ? "Due · \(row.from)" : "\(row.from) · \(row.at, style: .relative)").font(.headline).lineLimit(1)
                    Text(row.subject).font(.caption).lineLimit(2)
                }
                .widgetURL(AppGroup.Link.thread(row.id))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(isDue ? (snapshot.due.count == 1 ? "Due now" : "\(snapshot.due.count) due") : "Next reminder",
                              systemImage: row.isFollowUp ? "clock.arrow.circlepath" : "clock")
                            .font(.caption.weight(.semibold)).foregroundStyle(isDue ? WidgetPalette.reminder : .secondary)
                        Spacer()
                        Text(isDue ? "now" : Self.when(row.at)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    Link(destination: AppGroup.Link.thread(row.id)) {
                        RowView(row: row)
                    }
                    Spacer(minLength: 0)
                    HStack {
                        Button(intent: WidgetMarkDoneIntent(threadId: row.id)) {
                            Label("Done", systemImage: "checkmark").font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered).tint(WidgetPalette.accent)
                        if isDue {
                            Button(intent: WidgetSnoozeIntent(threadId: row.id)) {
                                Label("1 h", systemImage: "zzz").font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                        }
                        Spacer()
                        if snapshot.due.count + snapshot.upcoming.count > 1 {
                            Text("+\(snapshot.due.count + snapshot.upcoming.count - 1) more").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } else {
            EmptyWidgetView(title: "Nothing scheduled", systemImage: "clock", detail: "Swipe left on a thread to set a reminder.")
                .widgetURL(AppGroup.Link.folder("scheduled"))
        }
    }

    static func when(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { f.timeStyle = .short; f.dateStyle = .none }
        else if cal.isDateInTomorrow(date) { f.timeStyle = .short; f.dateStyle = .none; return "Tomorrow \(f.string(from: date))" }
        else { f.setLocalizedDateFormatFromTemplate("EEE HH:mm") }
        return f.string(from: date)
    }
}

// MARK: - Need reply

struct NeedReplyWidget: Widget {
    static let kind = "app.heypigeon.widget.needreply"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: SnapshotProvider()) { entry in
            NeedReplyView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Need reply")
        .description("The threads waiting on your answer.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct NeedReplyView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var shown: [WidgetSnapshot.Row] { Array(snapshot.needReply.prefix(family == .systemLarge ? 5 : 3)) }

    var body: some View {
        if shown.isEmpty {
            EmptyWidgetView(title: "Nothing to answer", systemImage: "arrowshape.turn.up.left", detail: "Flag a thread Need reply and it shows here.")
                .widgetURL(AppGroup.Link.folder("needReply"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(snapshot.needReplyTotal == 1 ? "1 needs a reply" : "\(snapshot.needReplyTotal) need a reply", systemImage: "arrowshape.turn.up.left")
                        .font(.caption.weight(.semibold)).foregroundStyle(WidgetPalette.needReply)
                    Spacer()
                }
                ForEach(shown) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Link(destination: AppGroup.Link.thread(row.id)) { RowView(row: row) }
                        Button(intent: WidgetMarkDoneIntent(threadId: row.id)) {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
                        .buttonStyle(.bordered).tint(WidgetPalette.accent)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Pieces

/// The inbox row, widget-sized: sender · time, subject, one preview line.
struct RowView: View {
    let row: WidgetSnapshot.Row

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(WidgetPalette.account(row.accountColor)).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.from).font(.caption.weight(row.isUnread ? .bold : .semibold)).lineLimit(1)
                Text(row.subject.isEmpty ? "(no subject)" : row.subject).font(.caption.weight(row.isUnread ? .semibold : .regular)).lineLimit(1)
                Text(row.snippet).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct EmptyWidgetView: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
