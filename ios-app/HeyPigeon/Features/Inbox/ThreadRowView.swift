// One inbox row, three lines: sender · marks · time, subject, one-line
// preview — plus a fourth line (the bundle, the triage labels as words)
// only when there is something to say. No avatar, no indent and no bar on
// the row's edge: unread is the sender in bold under the highlighter
// (`marker()`) with the time in ink, and a read row's sender steps back
// to the secondary grey. In the unified view the account is a small dot
// in its colour before the time. Done is struck through: while a swipe
// is about to mark the row done, and on a done email listed in its
// bundle, which also steps back to the tertiary grey
// (docs/specs/marker-look.md: R2, R3, R7, R10).

import SwiftUI

struct ThreadRowView: View {
    let row: ThreadRow
    let showAccountDot: Bool
    /// Search words to underline in the subject and snippet.
    var highlight: [String] = []
    /// The bundle's mark; off inside the bundle's own view.
    var showsBundle = true
    @Environment(AppModel.self) private var model
    /// Letting go of the swipe in progress would mark this row done
    /// (`SwipeableRow`): the subject and the preview are struck through
    /// meanwhile, as they will be.
    @Environment(\.swipeMarksDone) private var swipeMarksDone
    /// How far the account's dot stands off the first line's baseline, so
    /// that it sits at mid-height beside the time. It grows with the text.
    @ScaledMetric(relativeTo: .callout) private var dotLift: CGFloat = 3

    private var account: MailAccount? { model.account(for: row) }

    /// Done and still on screen, which the check beside the time says:
    /// anywhere but the Archive, where every row is and none needs
    /// telling apart.
    private var showsDone: Bool { row.isDone && model.view != .archive }

    /// A done email listed in its bundle's own view (under Done there,
    /// for reference): it steps back to the tertiary grey with its
    /// subject and preview struck through, as on the Mac. In a search or
    /// a folder a done thread reads as any other row, with the check
    /// beside its time: most of what a search finds is done, and a list
    /// of struck lines is hard to read.
    private var setBack: Bool { row.isDone && !showsBundle }

    /// The sender: ink while unread, the secondary grey once read, the
    /// tertiary one when the row is set back.
    private var senderInk: Color {
        if setBack { return Theme.textTertiary }
        return row.isRead ? Theme.textSecondary : Theme.textPrimary
    }

    /// The preview's face: 14, a step under the subject's 15, and scaled
    /// with it.
    private static func preview(_ weight: Font.Weight) -> Font {
        Theme.text(.preview, weight)
    }

    var body: some View {
        // A value, not the property: the guide's closure then holds a
        // number and nothing of the view.
        let lift = dotLift
        // The design has 3 pt between lines that are 22, 20 and 19 pt
        // tall. The faces' own lines are 19.5, 18.3 and 17 pt here, so the
        // 2 pt each one lacks go into the gap: the baselines stand as far
        // apart as they were drawn.
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.fromSummary)
                    .font(Theme.sender(!row.isRead))
                    .foregroundStyle(senderInk)
                    .lineLimit(1)
                    // Unread is this weight and the pink corner the list
                    // puts on the row (`unreadCorner`).
                if row.isConversation {
                    Text("\(row.messageCount)").font(Theme.meta).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                trailingMarks
                // Unified view: the account is a dot in its colour before
                // the time. Nothing in the sender's name is tinted, so the
                // highlighter is the only colour on the name.
                if showAccountDot, let account {
                    Circle().fill(Theme.state(account.color)).frame(width: 6, height: 6)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.bottom] + lift }
                        .accessibilityHidden(true)
                }
                Text(timeText)
                    .font(Theme.meta)
                    .foregroundStyle(row.isRead || setBack ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    // The time is never the one to give way: a long name
                    // is cut short first, at any text size.
                    .layoutPriority(1)
            }
            // The subject line carries what is said about the thread at
            // its end (the AI's suggestion, a draft, the paperclip);
            // labels and the bundle get their own line.
            HStack(spacing: 10) {
                highlighted(row.subject.isEmpty ? "(no subject)" : row.subject,
                            match: Theme.text(.bodySmall, .semibold))
                    .font(Theme.text(.bodySmall, row.isRead ? .regular : .semibold))
                    .foregroundStyle(setBack ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .struckThrough(setBack || swipeMarksDone)
                Spacer(minLength: 0)
                // The AI's proposal, read-only here (the row is a tap target
                // and a swipe surface): the thread and the long-press menu
                // accept or dismiss it.
                if let s = row.openSuggestion {
                    StateMark(text: s.title, systemImage: "sparkles", tint: Theme.pinkInk, weight: .medium)
                        .accessibilityLabel("Suggested: \(s.title)")
                }
                // An unsent reply waits in the thread (the Drafts folder needs no mark).
                if row.labels.contains("DRAFT"), model.view != .drafts {
                    StateMark(text: "Draft", tint: Theme.state(.coral), weight: .medium)
                }
                if row.hasAttachment {
                    Image(systemName: "paperclip").font(Theme.glyph(.caption)).foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true) // "Has attachment", in the row's value
                }
            }
            if !row.snippet.isEmpty {
                highlighted(row.snippet, match: Self.preview(.semibold))
                    .font(Self.preview(.regular))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .struckThrough(setBack || swipeMarksDone)
            }
            // What the mail is (its triage labels, as words) and what it
            // belongs to (the bundle), under the preview so the subject
            // keeps its width.
            if !triageNames.isEmpty || bundle != nil {
                HStack(spacing: 12) {
                    if let bundle { BundleChip(bundle: bundle) }
                    ForEach(triageNames, id: \.self) { name in
                        // Said by its name, as it was: the # is for the eye.
                        TagText(name).accessibilityLabel(name)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        // Unread is the highlighter and a font weight, the marks are bare
        // symbols: none of it was said aloud.
        .accessibilityValue(row.spokenState(showsDone: model.view != .archive))
        .accessibilityAddTraits(.isButton)
    }

    /// The text with every search word underlined in ink, set in `match`
    /// (the line's own face, a weight up) and lifted to the primary
    /// colour; plain text when there is nothing to mark.
    private func highlighted(_ text: String, match: Font) -> Text {
        guard !highlight.isEmpty else { return Text(text) }
        var marked = AttributedString(text)
        for word in highlight {
            var rest = marked.startIndex..<marked.endIndex
            while let hit = marked[rest].range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) {
                marked[hit].font = match
                marked[hit].foregroundColor = Theme.textPrimary
                marked[hit].underlineStyle = Text.LineStyle(pattern: .solid, color: Theme.textPrimary)
                rest = hit.upperBound..<marked.endIndex
            }
        }
        return Text(marked)
    }

    /// The row's bundle, unless the row is shown inside that bundle.
    private var bundle: BundleItem? {
        showsBundle ? model.bundle(id: row.bundleId) : nil
    }

    /// Jev labels on the row, by name (at most two; the rest is in the thread).
    private var triageNames: [String] {
        row.triageLabelIds.prefix(2).compactMap { model.triageLabelName($0) }
    }

    private var timeText: String {
        if model.view == .scheduled, let at = row.scheduledAt { return Formatters.reminder(at) }
        return Formatters.rowTime(row.lastMessageAt)
    }

    /// Small marks next to the time, only when true: each a glyph in its
    /// state's colour (a reminder lavender, Need reply sky, done mint),
    /// the pin in ink.
    @ViewBuilder
    private var trailingMarks: some View {
        if row.scheduledAt != nil {
            mark(row.isFollowUp ? "clock.arrow.circlepath" : "clock", Theme.state(.lavender))
        }
        if row.needsReply { mark("arrowshape.turn.up.left", Theme.state(.sky)) }
        if row.isPinned { mark("pin.fill", Theme.pin) }
        if showsDone { mark("checkmark", Theme.state(.mint)) }
    }

    private func mark(_ name: String, _ tint: Color) -> some View {
        // Said through the row's value (`spokenState`), not as symbol names.
        Image(systemName: name).font(Theme.glyph(.meta, .semibold)).foregroundStyle(tint).accessibilityHidden(true)
    }
}

/// Jev priority, the desktop's indicator: three short bars (1 lit = low,
/// 2 = medium, 3 = high; high in the alert colour), spam a blocked circle.
struct PriorityIndicator: View {
    let priority: TriageLevel

    var body: some View {
        if priority == .spam {
            Image(systemName: "circle.slash").font(.caption2.weight(.bold)).foregroundStyle(Theme.textTertiary)
                .accessibilityLabel("Likely spam")
        } else {
            let level = priority == .high ? 3 : priority == .medium ? 2 : 1
            // The state's colour as a mark on the paper: it has a lighter
            // pair for dark, where the fill's own was too dim.
            let lit = priority == .high ? Theme.state(.coral) : Theme.state(.amber)
            // A faint step of the text colour, in both appearances: the
            // fixed light grey it was outshone the lit bars on dark.
            let unlit = Theme.textTertiary.opacity(0.4)
            VStack(spacing: 2) {
                ForEach(1...3, id: \.self) { bar in
                    RoundedRectangle(cornerRadius: 1).fill(bar > 3 - level ? lit : unlit).frame(width: 11, height: 2)
                }
            }
            .help("Priority \(priority.rawValue)")
            .accessibilityLabel("Priority \(priority.rawValue)")
        }
    }
}
