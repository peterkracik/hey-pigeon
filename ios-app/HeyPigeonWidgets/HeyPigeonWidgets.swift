// The widget extension: Unread (small), Next reminder (medium), Need reply
// (medium), the reminder Live Activity and the Controls. Everything reads
// WidgetSnapshot from the App Group — the app writes it after every reload;
// buttons run WidgetMarkDoneIntent in the app's process and taps deep-link
// through heypigeon://.
//
// The same file is the Mac's widget extension (macos-app/project.yml): no
// Live Activities or Controls there, no Lock Screen families, and the Done
// and Snooze buttons are heypigeon://done and heypigeon://snooze links the
// app acts on when it opens — a Mac widget's intent runs in the extension,
// which has no engine.

import AppIntents
import SwiftUI
import WidgetKit

@main
struct HeyPigeonWidgetBundle: WidgetBundle {
    var body: some Widget {
        UnreadWidget()
        NextReminderWidget()
        NeedReplyWidget()
        #if os(iOS)
        ReminderLiveActivity()
        TriageLiveActivity()
        ComposeControl()
        ScheduledControl()
        InboxControl()
        #endif
    }
}

/// The families each widget offers: the Lock Screen accessories are iOS.
enum WidgetFamilies {
    static let unread: [WidgetFamily] = {
        #if os(iOS)
        [.systemSmall, .accessoryCircular, .accessoryRectangular]
        #else
        [.systemSmall]
        #endif
    }()

    static let reminder: [WidgetFamily] = {
        #if os(iOS)
        [.systemMedium, .accessoryRectangular]
        #else
        [.systemMedium]
        #endif
    }()
}

/// Done on a widget row: an intent that runs in the app's process on iOS,
/// a link that opens the app on the Mac (same mark-done, same Undo toast).
struct WidgetDoneButton<Content: View>: View {
    let threadId: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        Button(intent: WidgetMarkDoneIntent(threadId: threadId)) { content() }
            .buttonStyle(.bordered).tint(WidgetPalette.accent)
        #else
        Link(destination: AppGroup.Link.done(threadId)) {
            content()
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(WidgetPalette.accent.opacity(0.18), in: Capsule())
                .foregroundStyle(WidgetPalette.accent)
        }
        #endif
    }
}

/// "1 h" on a due reminder: the same two shapes as Done.
struct WidgetSnoozeButton: View {
    let threadId: String

    var body: some View {
        #if os(iOS)
        Button(intent: WidgetSnoozeIntent(threadId: threadId)) {
            Label("1 h", systemImage: "zzz").font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        #else
        Link(destination: AppGroup.Link.snooze(threadId)) {
            Label("1 h", systemImage: "zzz").font(.caption.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.fill.secondary, in: Capsule())
        }
        #endif
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
        .supportedFamilies(WidgetFamilies.unread)
    }
}

struct UnreadView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        #if os(iOS)
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
        #endif
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
        .supportedFamilies(WidgetFamilies.reminder)
    }
}

struct NextReminderView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var row: WidgetSnapshot.Row? { snapshot.due.first ?? snapshot.upcoming.first }
    private var isDue: Bool { !snapshot.due.isEmpty }

    /// The Lock Screen's rectangular slot (iOS only).
    private var isAccessory: Bool {
        #if os(iOS)
        family == .accessoryRectangular
        #else
        false
        #endif
    }

    var body: some View {
        if let row {
            if isAccessory {
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
                        WidgetDoneButton(threadId: row.id) {
                            Label("Done", systemImage: "checkmark").font(.caption.weight(.semibold))
                        }
                        if isDue {
                            WidgetSnoozeButton(threadId: row.id)
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
                        WidgetDoneButton(threadId: row.id) {
                            Image(systemName: "checkmark").font(.caption.weight(.bold))
                        }
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
