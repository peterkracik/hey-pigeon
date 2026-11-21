// The widget extension: Unread (small), Next reminder (medium), Need reply
// (medium), the Lock Screen versions of those, the triage and analysis Live
// Activities and the Controls. Everything reads WidgetSnapshot from the App
// Group — the app writes it after every reload; buttons run
// WidgetMarkDoneIntent in the app's process and taps deep-link through
// heypigeon://.
//
// The same file is the Mac's widget extension (macos-app/project.yml): no
// Live Activities or Controls there, no Lock Screen families, and the Done
// and Snooze buttons are heypigeon://done and heypigeon://snooze links the
// app acts on when it opens — a Mac widget's intent runs in the extension,
// which has no engine.
//
// Drawn in the app's look (docs/specs/marker-look.md) with what this
// target has in Theme's place: Typeface for the two faces and
// WidgetPalette for the colours. Counts and times are in the mono, a
// title is small mono capitals, an unread sender is bold under the
// highlighter, and a button is an ink capsule or its outline. The
// container is the system's and is left to it; so are the Lock Screen's
// accessories, whose colours the system replaces with its own.

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
        TriageLiveActivity()
        AnalysisLiveActivity()
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
        [.systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemMedium]
        #endif
    }()

    static let needReply: [WidgetFamily] = {
        #if os(iOS)
        [.systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        #else
        [.systemMedium, .systemLarge]
        #endif
    }()
}

/// Done on a widget row: an intent that runs in the app's process on iOS,
/// a link that opens the app on the Mac (same mark-done, same Undo toast).
/// It is the row's one action, so it is the ink capsule on both.
struct WidgetDoneButton<Content: View>: View {
    let threadId: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        Button(intent: WidgetMarkDoneIntent(threadId: threadId)) { capsule }
            .buttonStyle(.plain)
        #else
        Link(destination: AppGroup.Link.done(threadId)) { capsule }
        #endif
    }

    private var capsule: some View {
        content().modifier(WidgetCapsule(filled: true))
    }
}

/// "1 h" on a due reminder: the same two ways as Done, as an outlined
/// capsule beside Done's ink.
struct WidgetSnoozeButton: View {
    let threadId: String

    var body: some View {
        #if os(iOS)
        Button(intent: WidgetSnoozeIntent(threadId: threadId)) { capsule }
            .buttonStyle(.plain)
        #else
        Link(destination: AppGroup.Link.snooze(threadId)) { capsule }
        #endif
    }

    private var capsule: some View {
        Label("1 h", systemImage: "zzz").modifier(WidgetCapsule())
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
        // The Lock Screen's accessories: the count in the mono, and no
        // colour of the app's — the system draws them in its own.
        case .accessoryCircular:
            VStack(spacing: 0) {
                Image(systemName: "tray").font(.caption)
                Text("\(snapshot.unreadTotal)").font(Typeface.mono(.title3, .medium))
            }
        case .accessoryRectangular:
            HStack {
                Image(systemName: "tray")
                VStack(alignment: .leading) {
                    Text("\(snapshot.unreadTotal) unread").font(Typeface.sans(.subheadline, .semibold))
                    Text(snapshot.accounts.map { "\($0.name) \($0.unread)" }.joined(separator: " · ")).font(Typeface.sans(.caption)).lineLimit(1)
                }
            }
        #endif
        default:
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Image(systemName: "tray").foregroundStyle(WidgetPalette.textSecondary)
                    Spacer()
                    WidgetTitle(text: "Inbox")
                }
                Spacer(minLength: 0)
                Text("\(snapshot.unreadTotal)")
                    .font(Typeface.mono(size: 44, weight: .medium))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .contentTransition(.numericText())
                Text("unread").font(Typeface.sans(.caption)).foregroundStyle(WidgetPalette.textSecondary)
                    .padding(.top, 2)
                // One bar per account, in its colour, proportional to its share.
                if snapshot.accounts.count > 1, snapshot.unreadTotal > 0 {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(snapshot.accounts.filter { $0.unread > 0 }) { a in
                                Rectangle().fill(WidgetPalette.account(a.color))
                                    .frame(width: max(4, geo.size.width * CGFloat(a.unread) / CGFloat(snapshot.unreadTotal) - 2))
                            }
                        }
                    }
                    .frame(height: 5)
                    .padding(.top, 8)
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

    var body: some View {
        #if os(iOS)
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: card
        }
        #else
        card
        #endif
    }

    /// The due count, capped where the snapshot is: it keeps five rows.
    private var dueText: String {
        snapshot.due.count >= WidgetSnapshot.maxRows ? "\(WidgetSnapshot.maxRows)+" : "\(snapshot.due.count)"
    }

    #if os(iOS)
    /// Lock Screen status, not a list: how many are due, dimmed at zero.
    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: isDue ? "clock.badge.exclamationmark" : "clock").font(.caption).widgetAccentable(isDue)
            Text(dueText).font(Typeface.mono(.title3, .medium))
        }
        .opacity(isDue ? 1 : 0.6)
        .widgetURL(AppGroup.Link.folder("scheduled"))
    }

    private var rectangular: some View {
        Group {
            if let row {
                VStack(alignment: .leading, spacing: 1) {
                    Text(isDue ? "\(dueText) due" : "Next in \(row.at, style: .relative)").font(Typeface.sans(.subheadline, .semibold)).lineLimit(1)
                    Text("\(row.from) · \(row.subject.isEmpty ? "(no subject)" : row.subject)").font(Typeface.sans(.caption)).lineLimit(2)
                }
                .widgetURL(AppGroup.Link.thread(row.id))
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("No reminders").font(Typeface.sans(.subheadline, .semibold))
                    Text("Nothing scheduled").font(Typeface.sans(.caption))
                }
                .widgetURL(AppGroup.Link.folder("scheduled"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Group {
            if let row {
                Label {
                    if isDue { Text("\(dueText) due · \(row.from)") } else { Text("Next in \(row.at, style: .relative)") }
                } icon: {
                    Image(systemName: "clock")
                }
            } else {
                Label("No reminders", systemImage: "clock")
            }
        }
        .widgetURL(AppGroup.Link.folder("scheduled"))
    }
    #endif

    @ViewBuilder
    private var card: some View {
        if let row {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // Due is a state, said in the reminder's colour; a
                    // reminder still ahead is a plain title, with the
                    // reminder's clock before it.
                    WidgetTitle(text: isDue ? (snapshot.due.count == 1 ? "Due now" : "\(snapshot.due.count) due") : "Next reminder",
                                systemImage: row.isFollowUp ? "clock.arrow.circlepath" : "clock",
                                glyph: WidgetPalette.reminder,
                                tint: isDue ? WidgetPalette.reminder : nil)
                    Spacer()
                    Text(isDue ? "now" : Self.when(row.at))
                        .font(Typeface.mono(size: 11.5, relativeTo: .caption))
                        .foregroundStyle(WidgetPalette.textSecondary)
                }
                Link(destination: AppGroup.Link.thread(row.id)) {
                    RowView(row: row)
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    WidgetDoneButton(threadId: row.id) {
                        Label("Done", systemImage: "checkmark")
                    }
                    if isDue {
                        WidgetSnoozeButton(threadId: row.id)
                    }
                    Spacer()
                    if snapshot.due.count + snapshot.upcoming.count > 1 {
                        Text("+\(snapshot.due.count + snapshot.upcoming.count - 1) more")
                            .font(Typeface.mono(.caption2))
                            .foregroundStyle(WidgetPalette.textSecondary)
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
        .supportedFamilies(WidgetFamilies.needReply)
    }
}

struct NeedReplyView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var shown: [WidgetSnapshot.Row] { Array(snapshot.needReply.prefix(family == .systemLarge ? 5 : 3)) }

    var body: some View {
        #if os(iOS)
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        default: card
        }
        #else
        card
        #endif
    }

    private var countText: String {
        snapshot.needReplyTotal == 1 ? "1 needs a reply" : "\(snapshot.needReplyTotal) need a reply"
    }

    #if os(iOS)
    /// Lock Screen status: the total (the snapshot keeps its true count),
    /// dimmed at zero.
    private var circular: some View {
        VStack(spacing: 0) {
            Image(systemName: "arrowshape.turn.up.left").font(.caption).widgetAccentable(snapshot.needReplyTotal > 0)
            Text("\(snapshot.needReplyTotal)").font(Typeface.mono(.title3, .medium))
        }
        .opacity(snapshot.needReplyTotal > 0 ? 1 : 0.6)
        .widgetURL(AppGroup.Link.folder("needReply"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let row = snapshot.needReply.first {
                Text(countText).font(Typeface.sans(.subheadline, .semibold)).lineLimit(1)
                Text("\(row.from) · \(row.subject.isEmpty ? "(no subject)" : row.subject)").font(Typeface.sans(.caption)).lineLimit(2)
            } else {
                Text("Nothing to answer").font(Typeface.sans(.subheadline, .semibold))
                Text("No thread needs a reply").font(Typeface.sans(.caption))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(AppGroup.Link.folder("needReply"))
    }

    private var inline: some View {
        Label(snapshot.needReplyTotal == 0 ? "Nothing to answer" : countText, systemImage: "arrowshape.turn.up.left")
            .widgetURL(AppGroup.Link.folder("needReply"))
    }
    #endif

    @ViewBuilder
    private var card: some View {
        if shown.isEmpty {
            EmptyWidgetView(title: "Nothing to answer", systemImage: "arrowshape.turn.up.left", detail: "Flag a thread Need reply and it shows here.")
                .widgetURL(AppGroup.Link.folder("needReply"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    // The count is the state itself, said in its colour.
                    WidgetTitle(text: countText, systemImage: "arrowshape.turn.up.left",
                                glyph: WidgetPalette.needReply, tint: WidgetPalette.needReply)
                    Spacer()
                }
                // Ruled as the inbox's rows are: a hairline between two
                // rows, none over the first or under the last.
                VStack(spacing: 0) {
                    ForEach(shown) { row in
                        replyRow(row, first: row.id == shown.first?.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// One thread and its Done. The button draws a check alone, so it
    /// says what it does.
    private func replyRow(_ row: WidgetSnapshot.Row, first: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Link(destination: AppGroup.Link.thread(row.id)) { RowView(row: row) }
            WidgetDoneButton(threadId: row.id) {
                Image(systemName: "checkmark").font(.caption.weight(.bold))
            }
            .accessibilityLabel("Done")
        }
        .padding(.top, first ? 0 : 4)
        .padding(.bottom, 4)
        .overlay(alignment: .top) {
            if !first { WidgetRule() }
        }
    }
}

// MARK: - Pieces

/// The inbox row, widget-sized: the account's dot, the sender, the
/// subject, one preview line. Unread is what it is on the inbox's row: a
/// bold sender and a small pink corner at the row's foot. Read, the
/// sender steps back to a medium weight in the secondary grey.
struct RowView: View {
    let row: WidgetSnapshot.Row
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(WidgetPalette.account(row.accountColor)).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 1) {
                sender
                Text(row.subject.isEmpty ? "(no subject)" : row.subject)
                    .font(Typeface.sans(.caption, row.isUnread ? .semibold : .regular))
                    .foregroundStyle(WidgetPalette.textPrimary)
                    .lineLimit(1)
                Text(row.snippet)
                    .font(Typeface.sans(.caption2))
                    .foregroundStyle(WidgetPalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Unread: the app's pink corner (`unreadCorner()`, which this
        // target cannot see). Only in full colour: where the system
        // recolours the widget the weight says unread alone.
        .overlay(alignment: .bottomLeading) {
            if row.isUnread, renderingMode == .fullColor {
                WidgetCorner().fill(WidgetPalette.accent).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The sender: bold in ink while unread, medium in the secondary grey
    /// once read.
    private var sender: some View {
        Text(row.from)
            .font(Typeface.sans(.footnote, row.isUnread ? .bold : .medium))
            .foregroundStyle(row.isUnread ? WidgetPalette.textPrimary : WidgetPalette.textSecondary)
            .lineLimit(1)
    }
}

/// The triangle of the unread corner: its right angle bottom leading.
struct WidgetCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct EmptyWidgetView: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage).foregroundStyle(WidgetPalette.textSecondary)
            Spacer(minLength: 0)
            Text(title).font(Typeface.sans(.headline, .semibold)).foregroundStyle(WidgetPalette.textPrimary)
            Text(detail).font(Typeface.sans(.caption)).foregroundStyle(WidgetPalette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A widget's title: small mono capitals, as a section's title is in the
/// app (`SectionTitle`, which this target cannot see). A plain name
/// ("Inbox", "Next reminder") stands back in the light grey of titles. A
/// title that says a state ("2 due", "1 needs a reply") is that state's
/// writing and takes its colour; on a Live Activity, whose platter is
/// not the paper, it is ink. A glyph before the words keeps a colour of
/// its own: the state's, or the AI's pink ink.
struct WidgetTitle: View {
    let text: String
    var systemImage: String? = nil
    var glyph: Color = WidgetPalette.textSecondary
    /// The words' colour when they are not the title grey.
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(glyph)
                    .accessibilityHidden(true)
            }
            if let tint {
                words.foregroundStyle(tint)
            } else {
                words.foregroundStyle(WidgetPalette.titleInk)
            }
        }
    }

    private var words: some View {
        Text(text)
            .font(Typeface.mono(size: 11, weight: .medium, relativeTo: .caption2))
            .tracking(0.9)
            .textCase(.uppercase)
            .lineLimit(1)
    }
}

/// The hairline between two rows of a widget (the app's `RowRule`).
struct WidgetRule: View {
    var body: some View {
        Rectangle().fill(WidgetPalette.separator).frame(height: 1).accessibilityHidden(true)
    }
}

/// A button on a widget or a Live Activity as the look draws one: an ink
/// capsule with the paper's colour for its words (Done, a row's one
/// action), or the ink as an outline (1 h, Stop). Where the system
/// recolours the widget (a tinted Home Screen, StandBy at night) a fill
/// and its words would come out in the one colour, so there every
/// capsule is the outline. Goes on a button's label.
struct WidgetCapsule: ViewModifier {
    var filled = false
    var height: CGFloat = 28
    @Environment(\.widgetRenderingMode) private var renderingMode

    func body(content: Content) -> some View {
        let fills = filled && renderingMode == .fullColor
        return content
            .font(Typeface.sans(.caption, .semibold))
            .foregroundStyle(fills ? WidgetPalette.onPrimary : WidgetPalette.textPrimary)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: height)
            .background {
                if fills {
                    Capsule().fill(WidgetPalette.textPrimary)
                } else {
                    Capsule().strokeBorder(WidgetPalette.textPrimary, lineWidth: 1)
                }
            }
            .contentShape(Capsule())
    }
}
