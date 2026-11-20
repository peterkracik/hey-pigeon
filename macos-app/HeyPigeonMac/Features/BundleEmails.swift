// A bundle's Emails page on the Mac, and the switcher between its two
// pages (Emails · Info), handed to the shared bundle screen by BundlesPage
// (BundleScreenParts). The shared screen's own pieces are the phone's: its
// three-line rows in a grouped list with a ⊖ button on every row, under a
// bold section header and the system's segmented control, read as another
// app's inside this window. Here the emails are the window's list: the
// inbox's row (MailRow — one line, the hover bar, the trackpad swipes, the
// context menu, a click opening it in place), ruled, on the paper. Open
// emails first, under a rule and no title (the tab counts them); then the
// done ones under the list's light grey title, struck through and set
// back, and folded past three. ⊖ (not part of this bundle) is in the
// hover bar and the context menu.

import SwiftUI

/// Emails · Info as the toolbar's tabs are (TabPill: the shown one an ink
/// capsule), on a glass capsule: it floats over the top of the page,
/// which scrolls under it as the list does under the toolbar's own items.
struct BundlePageTabs: View {
    @Binding var page: BundlePage
    /// Beside "Emails", as the toolbar's tabs carry their counts.
    let openCount: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(BundlePage.allCases, id: \.self) { p in
                let count: Int? = p == .emails && openCount > 0 ? openCount : nil
                TabPill(title: p.title, count: count, on: page == p) { page = p }
                    .accessibilityLabel(count.map { "\(p.title), \($0) open" } ?? p.title)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
        .padding(.top, 4).padding(.bottom, 8)
        .frame(maxWidth: .infinity)
    }
}

/// The bundle's emails as the window lists mail.
struct BundleEmailList: View {
    let contents: BundleContents
    @Bindable var state: WindowState
    @State private var showDone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// More done emails than show without a fold.
    private var folds: Bool { contents.done.count > BundleScreen.doneShownUnfolded }

    var body: some View {
        List {
            if contents.bundle.isAutomatic {
                note("Made automatically. Choose ⊖ on an email that doesn't belong, or rename the bundle, and it's yours.",
                     systemImage: "sparkles")
            }
            if contents.threads.isEmpty {
                note("No emails yet. Choose Add to bundle… on an email; mail that shares its booking, order or tracking number follows on its own.",
                     systemImage: nil)
            }
            mailRows(contents.open, done: false)
            if !contents.done.isEmpty {
                doneTitle
                if showDone || !folds { mailRows(contents.done, done: true) }
            }
        }
        // The inbox list's own shape (InboxPage).
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 1)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .contentMargins(.top, 6, for: .scrollContent)
        .contentMargins(.bottom, 40, for: .scrollContent)
        .background(MacTheme.listBackground)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: state.expanded)
    }

    /// The rows of one group, ruled as a day's are in the inbox. The open
    /// ones have no title, so the group opens with the rule alone, along
    /// the first row's top edge; the done ones are struck through and set
    /// back.
    private func mailRows(_ rows: [ThreadRow], done: Bool) -> some View {
        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
            MailRow(row: row, state: state, isLast: index == rows.count - 1, opensGroup: !done && index == 0,
                    inBundle: true, dimmed: done)
        }
    }

    /// "Done" as the list titles a group (`SectionTitle`: the name, a
    /// rule, how many stand under it); past three done emails it is the
    /// fold's button — their count in its words, the chevron after the
    /// rule.
    @ViewBuilder private var doneTitle: some View {
        Group {
            if folds {
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showDone.toggle() }
                } label: {
                    SectionTitle(title: "\(contents.done.count) done") {
                        Image(systemName: showDone ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showDone ? "Hide the done emails" : "Show the done emails")
                .accessibilityLabel(showDone ? "Hide \(contents.done.count) done emails" : "Show \(contents.done.count) done emails")
            } else {
                SectionTitle("Done", count: contents.done.count)
                    // One stop for VoiceOver ("Done, 2"), as the inbox's
                    // day titles are.
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, MacLayout.listMargin).padding(.top, 18).padding(.bottom, 2)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// A quiet line over the rows, in from the edge as a group title is.
    private func note(_ text: String, systemImage: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let systemImage {
                // The AI's sparkle, in its pink ink.
                Image(systemName: systemImage).font(.system(size: 11))
                    .foregroundStyle(Theme.pinkInk)
                    .accessibilityHidden(true)
            }
            Text(text).font(Theme.sans(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, MacLayout.listMargin).padding(.top, 8).padding(.bottom, 10)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
