// The Mac window's look: paper, ink and one pink highlighter
// (docs/specs/marker-look.md), under the standard Mac toolbar. One white
// surface for the sidebar, the list and a thread; single-line rows, like
// a to-do list, parted by hairlines under light grey titles; a row tints
// under the pointer (Done is the first hover action, in ink) and opens in
// place between two rules. What floats — the batch bar, the thread's
// triage bar — is the paper with a hairline and one soft shadow; the
// Spotlight panel is the paper with an ink outline. Liquid Glass is kept
// for what the system draws (the toolbar's items) and for the two things
// that float like the phone's: the triage label pill and a bundle's page
// tabs. The phone's tokens (Theme) are the source for every colour and
// face; this file holds the window's own surfaces, measures and pieces.

import SwiftUI

enum MacTheme {
    /// The sidebar: the paper, parted from the content by a hairline.
    static let sidebar = Theme.canvas
    /// The content column behind the list and the thread.
    static let content = Theme.canvas
    /// A floating panel (the batch bar, the thread's bar, the Spotlight
    /// panel): the paper again on light, a step up on dark.
    static let panel = Theme.raised
    /// Behind the list: the paper itself. Rows are ruled, not carded, so
    /// there is no step between a list and its rows.
    static let listBackground = Theme.canvas
    /// The hairlines: between two rows, beside the sidebar, around a panel.
    static let hairline = Theme.separator
    /// A row under the pointer: the one grey step below the paper.
    static let hover = Theme.sunken
    /// The highlighted row: the open folder, the list's cursor, a
    /// selection. Ink at a few percent, so it is a step stronger than
    /// `hover` in both appearances and, being a tint, still shows on a
    /// row the pointer is on (an icon button's own hover).
    static let selected = Theme.textPrimary.opacity(0.09)
    /// The sidebar's collapsible titles: the light grey of every title of
    /// a group or a section (`Theme.titleInk`), their chevron and rule in
    /// it too.
    static let sectionHeader = Theme.titleInk
}

/// The window's measures.
enum MacLayout {
    /// The column of the list's single-line rows (and the Bundles page).
    /// A thread is read in `readingWidth`.
    static let maxWidth: CGFloat = 1120
    /// The sidebar's width.
    static let sidebarWidth: CGFloat = 232
    /// The sender column of a row.
    static let senderWidth: CGFloat = 180
    /// With the reading pane (View › Reading Pane): the list's column, its
    /// narrower sender column, and how wide the content must be for the
    /// pane to fit beside the list — under that the window is one column.
    static let paneListWidth: CGFloat = 420
    static let paneSenderWidth: CGFloat = 120
    static let paneMinWidth: CGFloat = 1000
    /// A page that is read, not scanned (an open thread, a bundle's
    /// Info): prose and short facts in a column as wide as Settings' form
    /// and the iPad's thread (`ReadableLayout.maxWidth`).
    static let readingWidth: CGFloat = 760
    /// The list's margin: how far a day's title, its rule and its rows
    /// stand in from the column's edges.
    static let listMargin: CGFloat = 24
    /// A row of the list: one line this tall.
    static let rowHeight: CGFloat = 40
}

/// The Mac's icon button, in the four sizes the app uses, each with the
/// measures its own copy had: the batch bar's, a row's hover bar, the
/// editor's tools and the inline reply's header. (They were four
/// implementations — `IconButton`, the row's `SmallIcon`, the editor
/// tools' `button`, the composer's `headerButton` — that differed only in
/// these numbers and in whether the pointer tints them.)
struct IconButton: View {
    enum Size {
        /// 32 pt: a bar's button, in ink; tints under the pointer.
        case regular
        /// 26 pt: a row's own button; tints, and its icon darkens.
        case small
        /// 28 pt: a formatting tool of the composer; no tint (the bar it
        /// sits on is the surface).
        case tool
        /// 24 pt: the inline reply's window and close buttons; quiet, no
        /// tint.
        case header

        var side: CGFloat {
            switch self {
            case .regular: 32
            case .small: 26
            case .tool: 28
            case .header: 24
            }
        }

        var symbol: CGFloat {
            switch self {
            case .regular: 15
            case .small, .tool: 12
            case .header: 11
            }
        }

        var weight: Font.Weight {
            switch self {
            case .regular: .regular
            case .small: .medium
            case .tool, .header: .semibold
            }
        }

        /// The pointer puts a tint behind the icon.
        var tintsOnHover: Bool { self == .regular || self == .small }
        var darkensOnHover: Bool { self == .small }

        var ink: Color {
            switch self {
            case .regular: Theme.textPrimary
            case .small, .tool: Theme.textSecondary
            case .header: Theme.textTertiary
            }
        }
    }

    let systemImage: String
    let help: String
    var size = Size.regular
    /// The icon's colour when it is not the size's own (a tool that is
    /// on, a tool on the dark floating bar).
    var tint: Color? = nil
    /// What VoiceOver says when the tooltip says more ("Bold (⌘B)").
    var label: String? = nil
    var disabled = false
    /// The one ink action of where the button stands (Done in a row's
    /// hover bar): the icon in `onPrimary` on an ink circle, with the
    /// pointer on it or not.
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    init(_ systemImage: String, help: String, size: Size = .regular, tint: Color? = nil, label: String? = nil,
         disabled: Bool = false, prominent: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.size = size
        self.tint = tint
        self.label = label
        self.disabled = disabled
        self.prominent = prominent
        self.action = action
    }

    private var ink: Color {
        if prominent { return Theme.onPrimary }
        if disabled { return Theme.textTertiary.opacity(0.6) }
        if let tint { return tint }
        return hovering && size.darkensOnHover ? Theme.textPrimary : size.ink
    }

    private var fill: Color {
        if prominent { return Theme.textPrimary.opacity(disabled ? 0.35 : 1) }
        return hovering && !disabled && size.tintsOnHover ? MacTheme.selected : Color.clear
    }

    /// A circle for the ink action; the 6 pt corner of what is boxed for
    /// the pointer's tint.
    private var shape: RoundedRectangle {
        prominent
            ? RoundedRectangle(cornerRadius: size.side / 2, style: .circular)
            : RoundedRectangle(cornerRadius: 6, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size.symbol, weight: prominent ? .bold : size.weight))
                .foregroundStyle(ink)
                .frame(width: size.side, height: size.side)
                .background(fill, in: shape)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(label ?? help)
    }
}

/// One tab of a capsule switcher: the toolbar's Inbox · Remind me · Need
/// reply (ViewTabs) and a bundle's Emails · Info (BundlePageTabs). The
/// shown one is an ink capsule with the paper's colour for its words
/// (selection is ink) and its count beside it in the mono, a step
/// lighter; the others are plain words in the secondary grey. The
/// system's segmented control fills its selection with the system blue,
/// a hue the app has no other use for.
struct TabPill: View {
    let title: String
    var count: Int? = nil
    /// The count's colour while the tab is not the shown one.
    var countColor: Color = Theme.textTertiary
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Theme.sans(size: 13, weight: on ? .semibold : .medium))
                if let count {
                    Text("\(count)")
                        .font(Theme.mono(size: 11, weight: .medium))
                        .foregroundStyle(on ? Theme.onPrimary.opacity(0.75) : countColor)
                }
            }
            .foregroundStyle(on ? Theme.onPrimary : Theme.textSecondary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(on ? Theme.textPrimary : Color.clear, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// A full-width hairline.
struct Hairline: View {
    var body: some View {
        Rectangle().fill(MacTheme.hairline).frame(height: 1)
    }
}

/// A key as the look draws one: its letters in the mono inside a box with
/// a 1 pt outline and 4 pt corners.
struct KeyCap: View {
    let key: String
    var ink: Color = Theme.textSecondary

    var body: some View {
        Text(key)
            .font(Theme.mono(size: 11))
            .foregroundStyle(ink)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(minWidth: 20)
            .frame(height: 20)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.outline, lineWidth: 1))
    }
}

/// A shortcut as the palette's rows and the shortcuts sheet show it: each
/// key a cap of its own, the words between them ("·", "then", "…") plain.
/// VoiceOver reads the shortcut as it is written.
struct KeyCaps: View {
    let keys: String
    /// The letters' colour: ink where the keys are what is read (the
    /// shortcuts sheet), a step quieter beside a command's name.
    var ink: Color = Theme.textSecondary

    /// What stands between two keys of a shortcut without being one.
    private static let joiners: Set<String> = ["·", "then", "…"]

    /// The shortcut's pieces in order and which of them are keys:
    /// "J · K" is two keys around a dot, "G then I" two around a word,
    /// "G I" (the palette's) two keys. Pure, so it can be tested.
    static func parts(_ keys: String) -> [(text: String, isKey: Bool)] {
        keys.split(separator: " ").map { piece in
            let text = String(piece)
            return (text: text, isKey: !joiners.contains(text))
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(Self.parts(keys).enumerated()), id: \.offset) { _, part in
                if part.isKey {
                    KeyCap(key: part.text, ink: ink)
                } else {
                    Text(part.text).font(Theme.mono(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys)
    }
}

/// An icon button as the one ink action of the window's toolbar (New
/// message): the glyph in `onPrimary` on an ink circle. A style, so the
/// button keeps its `Label` — the toolbar's overflow menu and VoiceOver
/// read its title.
struct InkCircleButtonStyle: ButtonStyle {
    var side: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.onPrimary)
            .frame(width: side, height: side)
            .background(Theme.textPrimary, in: Circle())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Circle())
    }
}

/// An empty state of the window ("No thread open"): the system's
/// `ContentUnavailableView`, with its title in the display face, drawn a
/// little tight, as the phone's empty states and a sheet's title are, and
/// its symbol standing back in the tertiary grey. Both are set on the
/// text and the image themselves, where the system's own style does not
/// replace them.
struct MacEmptyState: View {
    let title: String
    let systemImage: String
    /// A line under the title that says what to do.
    var detail: String? = nil

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title).font(Theme.display(24, relativeTo: .title2)).tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.textTertiary)
            }
        } description: {
            if let detail {
                Text(detail).font(Theme.sans(size: 13)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}

extension View {
    /// A floating panel: the paper, a hairline border, one soft shadow —
    /// in place of the phone's glass. Never around a message: the shadow
    /// would fall on its web view too.
    func macPanel(cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(MacTheme.panel, in: shape)
            .overlay(shape.strokeBorder(MacTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 2)
    }
}
