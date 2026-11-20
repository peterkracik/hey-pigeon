// A bundle's Info page on the Mac, handed to the shared bundle screen by
// BundlesPage (BundleScreenParts) as its Emails page is. The shared page
// is the phone's grouped list; in this window it lay straight on the
// canvas with bold list headers over full-width dividers and rows
// stretched across the window. Here it is drawn as the Emails page
// beside it is: on the paper, each section under the list's light grey
// title (`SectionTitle`) with hairlines between its rows and no card
// around them, in a reading column (Settings' width) — the summary is
// prose, and a kind, a number and a date 1900 pt apart are no row.
//
// Top to bottom: the bundle's description; Summary (the model's status
// line and what is left to do, with its refresh after the title's
// rule); Tracking, one row per shipment (BundleTracking: a carrier's or
// shop's name instead of a host, the links of one parcel folded under
// its newest email); Key facts, kind by kind, their values in the mono.
// A row is one line that tints under the pointer, where the time gives
// way to its actions, as a mail row's does. What a row is for is its
// click: a shipment opens its tracking page, a fact is copied (an
// identifier is there to be pasted somewhere). The rest — the email it
// came from, Copy link, Track — is in the hover bar and the context menu.

import SwiftUI

struct BundleInfoPage: View {
    let contents: BundleContents
    @Bindable var state: WindowState
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    /// The summary has something to read or to ask for.
    private var showsSummary: Bool { model.aiConfigured && !contents.threads.isEmpty }

    var body: some View {
        let shipments = BundleTracking.shipments(links: contents.links, facts: contents.facts)
        let facts = BundleTracking.byKind(contents.facts)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !contents.bundle.description.isEmpty {
                    Text(contents.bundle.description)
                        .font(Theme.sans(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 4).padding(.top, 10)
                }
                if showsSummary {
                    let brief = model.brief(for: contents)
                    title("Summary", trailing: AnyView(summaryControl(brief)))
                    section { BundleSummary(state: brief) { model.summarizeBundle(contents) } }
                }
                if !shipments.isEmpty {
                    title("Tracking")
                    section {
                        ForEach(shipments) { shipment in
                            shipmentRow(shipment, isLast: shipment.id == shipments.last?.id)
                        }
                    }
                }
                if !facts.isEmpty {
                    title("Key facts")
                    section {
                        ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                            factRow(fact, namesKind: index == 0 || facts[index - 1].category != fact.category,
                                    isLast: index == facts.count - 1)
                        }
                    }
                }
                if shipments.isEmpty && facts.isEmpty && !showsSummary {
                    Text("Nothing to show yet: booking, order and tracking numbers appear here as the bundle's mail arrives.")
                        .font(Theme.sans(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4).padding(.top, 16)
                }
            }
            .frame(maxWidth: MacLayout.readingWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.never)
        .contentMargins(.top, 6, for: .scrollContent)
        .contentMargins(.bottom, 40, for: .scrollContent)
        .background(MacTheme.listBackground)
    }

    // MARK: Pieces

    /// A section's title as the list titles a day (`SectionTitle`: the
    /// name in small mono capitals and a rule filling the line, in the
    /// light grey of titles), a control after the rule where there is
    /// one — it is something to press, so it keeps its own strength.
    private func title(_ text: String, trailing: AnyView? = nil) -> some View {
        SectionTitle(title: text) { trailing }
        // As tall with a control in it as without: the titles keep one
        // rhythm down the page.
        .frame(height: 26)
        .padding(.top, 10).padding(.bottom, 2)
    }

    /// A section's rows, one under the other on the paper: hairlines
    /// between them (each row draws its own), no card and no fill.
    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// After "Summary" and its rule: the model at work, or the way to ask
    /// it again. The first ask and a failed one are buttons in the
    /// section itself.
    @ViewBuilder private func summaryControl(_ brief: BundleBriefState?) -> some View {
        if brief?.generating == true {
            // The one spinner on the page: the model's answer comes from
            // the network (or the on-device model), not the store.
            ProgressView().controlSize(.small).padding(.trailing, 6)
                .accessibilityLabel("Summarizing")
        } else if brief?.brief != nil {
            IconButton("arrow.clockwise", help: "Summarize again", size: .small) { model.summarizeBundle(contents) }
        }
    }

    // MARK: Tracking

    /// The carrier or shop from the link's host; for a redirect's host
    /// the email's sender, who is the carrier; the host when all else fails.
    private func name(of link: BundleLinkItem) -> String {
        if let name = BundleTracking.name(host: link.host) { return name }
        return thread(link.threadId)?.leadSenderName ?? link.host
    }

    private func thread(_ id: String) -> ThreadRow? {
        contents.threads.first { $0.id == id }
    }

    private func shipmentRow(_ shipment: BundleTracking.Shipment, isLast: Bool) -> some View {
        let link = shipment.link
        let who = name(of: link)
        let status = link.subject.isEmpty ? link.host : link.subject
        let earlier = shipment.earlier.count
        return BundleInfoRow(
            time: thread(link.threadId).map { Formatters.rowTime($0.lastMessageAt) } ?? "",
            label: "\(who), \(status)" + (earlier > 0 ? ", \(earlier) earlier" : ""),
            help: "Open the tracking page",
            actions: [
                BundleInfoAction(title: "Open Tracking Page", systemImage: "arrow.up.right") { openURL(link.url) },
                BundleInfoAction(title: "Open the Email", systemImage: "envelope") { open(link.threadId) },
                BundleInfoAction(title: "Copy Link", systemImage: "doc.on.doc") { copy(link.url.absoluteString, saying: "Copied the link") },
            ],
            // The emails that came before the newest one, under the menu.
            more: shipment.earlier.map { old in
                BundleInfoAction(title: old.subject.isEmpty ? old.host : old.subject, systemImage: "clock.arrow.circlepath") {
                    open(old.threadId)
                }
            },
            moreTitle: "Earlier updates",
            ruled: !isLast,
            primary: { openURL(link.url) }
        ) {
            Image(systemName: "shippingbox")
                .font(.system(size: 12))
                .foregroundStyle(Theme.state(.sky))
                .frame(width: 18)
            Text(who)
                .font(Theme.sans(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
            Text(status)
                .font(Theme.sans(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            if earlier > 0 {
                Text("+\(earlier) earlier")
                    .font(Theme.tag)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    // MARK: Key facts

    private func factRow(_ fact: BundleFactItem, namesKind: Bool, isLast: Bool) -> some View {
        var actions = [
            BundleInfoAction(title: "Copy", systemImage: "doc.on.doc") { copy(fact.value, saying: "Copied \(fact.value)") },
            BundleInfoAction(title: "Open the Email", systemImage: "envelope") { open(fact.threadId) },
        ]
        if let url = fact.url {
            actions.append(BundleInfoAction(title: "Track", systemImage: "arrow.up.right") { openURL(url) })
        }
        return BundleInfoRow(
            time: Formatters.rowTime(fact.at),
            label: "\(fact.category.title) \(fact.value)",
            help: "Copy \(fact.value)",
            actions: actions,
            // A tracking number's link is what the row is most often
            // wanted for, so it shows without the pointer.
            chip: fact.url.map { url in BundleInfoAction(title: "Track", systemImage: "arrow.up.right") { openURL(url) } },
            ruled: !isLast,
            primary: { copy(fact.value, saying: "Copied \(fact.value)") }
        ) {
            // A kind is named on its first row; the rows under it line
            // up on the value.
            Image(systemName: fact.category.systemImage)
                .font(.system(size: 12))
                .foregroundStyle(Theme.state(.sky))
                .frame(width: 18)
                .opacity(namesKind ? 1 : 0)
            Text(fact.category.title)
                .font(Theme.sans(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .frame(width: 132, alignment: .leading)
                .opacity(namesKind ? 1 : 0)
            // An identifier is data: in the mono.
            Text(fact.value)
                .font(Theme.mono(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: Actions

    /// The email a row came from, in the page's stack, over the bundle.
    private func open(_ threadId: String) {
        guard let row = model.row(forThreadId: threadId) ?? thread(threadId) else { return }
        state.open(row, in: model)
    }

    private func copy(_ text: String, saying toast: String) {
        Clipboard.copy(text)
        model.show(toast)
    }
}

/// One thing a row can do: in its hover bar, its context menu and, for
/// VoiceOver, its actions.
struct BundleInfoAction: Identifiable {
    let title: String
    let systemImage: String
    let run: () -> Void
    var id: String { title + systemImage }
}

/// One line of the Info page: what it is at the leading end, when at the
/// trailing end in the mono, a hairline under it; under the pointer the
/// row is the sunken grey and the time gives way to the actions, as on a
/// mail row. The line is a button of its own, so the row is reachable
/// with the keyboard and reads as one element.
private struct BundleInfoRow<Line: View>: View {
    let time: String
    /// What VoiceOver reads for the line.
    let label: String
    /// What a click does, for the tooltip and VoiceOver's hint.
    let help: String
    let actions: [BundleInfoAction]
    /// An action shown without the pointer, as a small boxed chip before
    /// the time.
    var chip: BundleInfoAction? = nil
    /// More for the context menu only, under their own title.
    var more: [BundleInfoAction] = []
    var moreTitle = ""
    /// A hairline under the row: every row of a section but its last.
    var ruled = true
    let primary: () -> Void
    @ViewBuilder let line: () -> Line
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: primary) {
                HStack(spacing: 10) {
                    line()
                    Spacer(minLength: 8)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .accessibilityLabel(label)
            .accessibilityHint(help)
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.title) { action.run() }
                }
            }
            if let chip {
                // Boxed, not filled: a word in the mono inside the
                // outline, as every chip that can be pressed is.
                Button(action: chip.run) {
                    HStack(spacing: 3) {
                        Text(chip.title).font(Theme.tag)
                        Image(systemName: chip.systemImage).font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 7).frame(height: 20)
                    .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovering ? 0 : 1)
                .accessibilityHidden(hovering)
            }
            ZStack(alignment: .trailing) {
                Text(time)
                    .font(Theme.meta)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .opacity(hovering ? 0 : 1)
                    .accessibilityHidden(true)
                if hovering {
                    HStack(spacing: 0) {
                        ForEach(actions) { action in
                            IconButton(action.systemImage, help: action.title, size: .small, action: action.run)
                        }
                    }
                }
            }
            .frame(minWidth: 72, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .frame(height: MacLayout.rowHeight)
        .background(hovering ? MacTheme.hover : Color.clear)
        .overlay(alignment: .bottom) {
            if ruled { RowRule() }
        }
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .contextMenu {
            ForEach(actions) { action in
                Button { action.run() } label: { Label(action.title, systemImage: action.systemImage) }
            }
            if !more.isEmpty {
                Section(moreTitle) {
                    ForEach(more) { action in
                        Button { action.run() } label: { Label(action.title, systemImage: action.systemImage) }
                    }
                }
            }
        }
    }
}

/// The model's brief under the Summary title, in the window's type:
/// where things stand as a short paragraph, then what is left for the
/// user. The to-dos are the model's words, not tasks the app keeps, so
/// they carry a mark — the AI's, in its pink ink — and no circle: a
/// circle is something to tick, and nothing here could remember the tick.
private struct BundleSummary: View {
    let state: BundleBriefState?
    let refresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let brief = state?.brief {
                if !brief.status.isEmpty {
                    Text(SummaryMarkup.inline(brief.status))
                        .font(Theme.sans(size: 14.5))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !brief.actions.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("To do")
                            .font(Theme.label)
                            .tracking(Theme.labelTracking)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(brief.actions, id: \.self) { action in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.pinkInk)
                                    .accessibilityHidden(true)
                                Text(SummaryMarkup.inline(action))
                                    .font(Theme.sans(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                if brief.status.isEmpty && brief.actions.isEmpty {
                    quiet("Nothing to report on this bundle.")
                }
            } else if let error = state?.error {
                quiet(error)
                ask("Try again", systemImage: "arrow.clockwise")
            } else if state?.generating == true {
                quiet("Reading the bundle…")
            } else {
                quiet("Where things stand and what is left to do, from the bundle's latest emails.")
                ask("Summarize", systemImage: "sparkles")
            }
        }
        .padding(.horizontal, 4).padding(.top, 10).padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quiet(_ text: String) -> some View {
        Text(text)
            .font(Theme.sans(size: 13))
            .foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func ask(_ title: String, systemImage: String) -> some View {
        Button(action: refresh) {
            // The words in the app's face, the glyph in the system's.
            Label {
                Text(title).font(Theme.sans(size: 12, weight: .semibold))
            } icon: {
                Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
            }
        }
        .pillButton()
    }
}
