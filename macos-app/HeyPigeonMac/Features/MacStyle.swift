// The Mac window's look, after the first desktop client (desktop-app, the
// Svelte one): quiet and flat under the standard Mac toolbar. A grey
// sidebar; single-line rows with a done circle, like a to-do list, that
// only tint on hover; the open row as a card; the batch bar and the toast
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

/// The window's measures.
enum MacLayout {
    /// The readable column the list and the thread share.
    static let maxWidth: CGFloat = 1120
    /// The sidebar's width.
    static let sidebarWidth: CGFloat = 232
    /// The sender column of a row.
    static let senderWidth: CGFloat = 180
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
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(disabled ? Theme.textTertiary.opacity(0.6) : Theme.textSecondary)
                .frame(width: 32, height: 32)
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
