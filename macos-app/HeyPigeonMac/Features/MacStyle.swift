// The Mac window's look, after the first desktop client (desktop-app, the
// Svelte one): quiet and flat under the standard Mac toolbar. A grey
// sidebar; single-line rows, like a to-do list, that only tint on hover
// (Done is the first hover action); the open row as a card; the batch bar and the toast
// on a bordered panel with a soft shadow. Liquid Glass is kept for what
// floats over the content like the phone's: the triage label pill and the
// Spotlight search panel. The phone's tokens (Theme) stay the source for text
// and accent colours.

import SwiftUI

enum MacTheme {
    /// The sidebar: a step darker than the content in both appearances.
    static let sidebar = Color(light: Color(hex: 0xEFEFED), dark: Color(hex: 0x161518))
    /// The content column behind the list and the thread.
    static let content = Theme.canvas
    /// A floating panel (the batch bar, the toast).
    static let panel = Theme.card
    /// Behind the list: a step below the white group cards.
    static let listBackground = Color(light: Color(hex: 0xF3F3F1), dark: Color(hex: 0x19181B))
    /// A day group's card (Pinned, Today, Last 7 days…) holding its rows.
    static let groupCard = Color(light: .white, dark: Color(hex: 0x252428))
    /// The hairlines: under the title row, beside the sidebar, around a panel.
    static let hairline = Theme.separator
    /// A row under the pointer.
    static let hover = Color(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.05))
    /// The highlighted row: the open folder, the list's cursor.
    static let selected = Color(light: Color.black.opacity(0.075), dark: Color.white.opacity(0.09))
    /// Small grey section headers in the sidebar.
    static let sectionHeader = Theme.textTertiary
}

/// The window's measures.
enum MacLayout {
    /// The readable column the list and the thread share.
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
    /// A page that is read, not scanned (a bundle's Info): prose and
    /// short facts in a column as wide as Settings' form.
    static let readingWidth: CGFloat = 760
}

/// One icon, no chrome until the pointer is on it: the batch bar's
/// buttons and, in the smaller size, a row's hover bar. (The row had a
/// copy of its own, `SmallIcon`, that differed only in its measures.)
struct IconButton: View {
    /// The two sizes the window uses, each with the measures it had.
    enum Size {
        /// 32 pt: a bar's button.
        case regular
        /// 26 pt: a row's own button, whose icon darkens under the pointer.
        case small

        var side: CGFloat { self == .regular ? 32 : 26 }
        var symbol: CGFloat { self == .regular ? 15 : 12 }
        var weight: Font.Weight { self == .regular ? .regular : .medium }
        var cornerRadius: CGFloat { self == .regular ? 7 : 6 }
        var darkensOnHover: Bool { self == .small }
    }

    let systemImage: String
    let help: String
    var size = Size.regular
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    init(_ systemImage: String, help: String, size: Size = .regular, disabled: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.size = size
        self.disabled = disabled
        self.action = action
    }

    private var ink: Color {
        if disabled { return Theme.textTertiary.opacity(0.6) }
        return hovering && size.darkensOnHover ? Theme.textPrimary : Theme.textSecondary
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size.symbol, weight: size.weight))
                .foregroundStyle(ink)
                .frame(width: size.side, height: size.side)
                .background(hovering && !disabled ? MacTheme.selected : .clear,
                            in: RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One tab of a capsule switcher: the toolbar's Inbox · Remind me · Need
/// reply (ViewTabs) and a bundle's Emails · Info (BundlePageTabs). The
/// shown one in bold on a light pill, a count beside the title. The
/// system's segmented control fills its selection with the system blue,
/// a hue the app has no other use for.
struct TabPill: View {
    let title: String
    var count: Int? = nil
    var countColor: Color = Theme.textTertiary
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13, weight: on ? .semibold : .regular))
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(countColor)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(on ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(on ? MacTheme.selected : .clear, in: Capsule())
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

extension View {
    /// A floating panel: the content surface, a hairline border, a soft
    /// shadow — in place of the phone's glass.
    func macPanel(cornerRadius: CGFloat = 10) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(MacTheme.panel, in: shape)
            .overlay(shape.strokeBorder(MacTheme.hairline, lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }
}
