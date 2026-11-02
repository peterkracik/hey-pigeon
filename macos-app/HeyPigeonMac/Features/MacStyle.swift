// The Mac window's look: quiet and flat, in the manner of the Claude
// desktop app — a grey sidebar beside a plain content surface, a slim
// title row over a hairline, rows that only tint on hover and selection,
// borderless icon buttons that light up under the pointer, and floating
// pieces (the hover actions, the batch bar, the toast, the search field)
// on a bordered panel with a soft shadow instead of Liquid Glass. The
// phone's tokens (Theme) stay the source for text and accent colours.

import SwiftUI

enum MacTheme {
    /// The sidebar: a step darker than the content in both appearances.
    static let sidebar = Color(light: Color(hex: 0xEFEFED), dark: Color(hex: 0x161518))
    /// The content column behind the list and the thread.
    static let content = Theme.canvas
    /// A floating panel (the batch bar, the toast, the search field).
    static let panel = Theme.card
    /// The hairlines: under the title row, beside the sidebar, around a panel.
    static let hairline = Theme.separator
    /// A row under the pointer.
    static let hover = Color(light: Color.black.opacity(0.04), dark: Color.white.opacity(0.05))
    /// The highlighted row: the open folder, the list's cursor.
    static let selected = Color(light: Color.black.opacity(0.075), dark: Color.white.opacity(0.09))
    /// Small grey section headers in the sidebar.
    static let sectionHeader = Theme.textTertiary
}

extension MacLayout {
    /// The title row's height: its contents line up with the traffic lights.
    static let titleRow: CGFloat = 30
    /// The room under the title row before the hairline.
    static let titleBottom: CGFloat = 8
    /// The sidebar's width.
    static let sidebarWidth: CGFloat = 248
}

/// One icon, no chrome until the pointer is on it: the title row's and the
/// sidebar's buttons.
struct IconButton: View {
    let systemImage: String
    let help: String
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    init(_ systemImage: String, help: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.help = help
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(disabled ? Theme.textTertiary.opacity(0.6) : Theme.textSecondary)
                .frame(width: 28, height: 28)
                .background(hovering && !disabled ? MacTheme.selected : .clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The title row's menu: a title with a small chevron that opens the
/// view's actions, like a conversation's title in the Claude app.
struct TitleMenu<Title: View, Items: View>: View {
    let items: () -> Items
    let label: () -> Title
    @State private var hovering = false

    init(@ViewBuilder items: @escaping () -> Items, @ViewBuilder label: @escaping () -> Title) {
        self.items = items
        self.label = label
    }

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: 6) {
                label()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovering ? MacTheme.hover : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
    }
}

/// The title text itself.
struct TitleText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
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

    /// The title row's frame: the row height the traffic lights sit in, the
    /// side padding, the room before the hairline.
    func titleRow() -> some View {
        frame(height: MacLayout.titleRow)
            .padding(.horizontal, 10)
            .padding(.bottom, MacLayout.titleBottom)
    }
}
