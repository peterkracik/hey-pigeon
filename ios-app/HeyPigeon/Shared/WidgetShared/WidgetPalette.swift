// The look's colours for the targets that cannot see Theme: the widgets,
// the Live Activities and the share extension (docs/specs/marker-look.md:
// paper, ink and one pink highlighter). Theme.swift needs the app's model
// types and Platform.swift, and neither is compiled into an extension;
// this folder is compiled into the app and both extensions, so the file
// stands on SwiftUI and the platform's own colour alone. The names and
// the values are Theme's: change one, change the other.

import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum WidgetPalette {
    // MARK: Ink

    /// Ink: content, a count, an action (`Theme.textPrimary`).
    static let textPrimary = pair(0x0B0D12, 0xF3F4F6)
    /// Writing on an ink fill, a widget's Done: the paper
    /// (`Theme.onPrimary`).
    static let onPrimary = pair(0xFFFFFF, 0x16181D)
    /// A read sender, a quiet line under a count, a time
    /// (`Theme.textSecondary`).
    static let textSecondary = pair(0x454850, 0xB6B9C0)
    /// The lightest grey that is still read: a row's preview, a note
    /// (`Theme.textTertiary`).
    static let textTertiary = pair(0x6B6E76, 0x8B8E96)
    /// A widget's title, and the rule that opens the share sheet's list:
    /// structure, so half the tertiary grey, and the whole of it with
    /// Increase Contrast (`Theme.titleInk`).
    static let titleInk = WidgetTitleInk()
    /// The rule between two rows (`Theme.separator`).
    static let separator = pair(0xE7E7EA, 0x2B2E36)
    /// A sheet's paper: the share sheet. The paper white on light, a step
    /// up on dark (`Theme.raised`).
    static let raised = pair(0xFFFFFF, 0x1E2026)
    /// The tint of the Lock Screen's platter under a Live Activity: black
    /// at 60 %, the same in both appearances, with the wallpaper showing
    /// through. It is not the paper, so what stands on it is drawn with
    /// the dark column of this palette (the activity sets its colour
    /// scheme), and the system's own button on it is `onPlatter`.
    static let platter = Color.black.opacity(0.6)
    static let onPlatter = Color.white

    // MARK: Pink

    /// The pink as a fill: here only the Dynamic Island's keyline, the
    /// same in both appearances (`Theme.accent`; in the app it is the
    /// AI's own button). As a mark it is `marker`, as writing `pinkInk`.
    static let accent = hex(0xEE4D9B)
    /// The highlighter: the band behind an unread sender. Half the pink
    /// on dark, where the pale band would glare (`Theme.marker`).
    static let marker = pair(light: hex(0xFFC9E2), dark: hex(0xEE4D9B).opacity(0.5))
    /// Pink as a glyph, the AI's sparkle: dark enough to read on the
    /// paper, light enough on dark (`Theme.pinkInk`).
    static let pinkInk = pair(0xCC2277, 0xF58BBE)

    // MARK: States

    /// A state as writing or a glyph (a reminder's clock, "Need reply",
    /// an account's dot), by the account colour's raw name: the tag's
    /// colour on light, a lighter step of it on dark (`Theme.state(_:)`).
    /// Made once: a pair is a dynamic platform colour.
    private static let states: [String: Color] = [
        "coral": pair(0xB34E2E, 0xF0916F),
        "mint": pair(0x1F7A5C, 0x5CC6A0),
        "lavender": pair(0x6A4FC4, 0xA995F2),
        "sky": pair(0x2A6BAE, 0x7FB2E8),
        "amber": pair(0xA9761E, 0xE3B341),
    ]

    /// The colour an unknown name falls back to: sky, the first account's.
    private static let sky = pair(0x2A6BAE, 0x7FB2E8)

    /// An account's colour, for its dot on a row and its share of the
    /// Unread widget's bar.
    static func account(_ raw: String) -> Color {
        states[raw] ?? sky
    }

    /// Need reply: the sky state.
    static let needReply = account("sky")
    /// A reminder: the lavender state.
    static let reminder = account("lavender")
    /// Done (a pass that has finished): the mint state. Never pink, which
    /// only ever means "look here".
    static let done = account("mint")
    /// Something went wrong, as a line of text: the coral state
    /// (`Theme.dangerText`).
    static let dangerText = account("coral")

    // MARK: Making a colour

    /// `0xRRGGBB`, sRGB, opaque: Theme's `Color(hex:)`, which the
    /// extensions do not have.
    private static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    private static func pair(_ light: UInt32, _ dark: UInt32) -> Color {
        pair(light: hex(light), dark: hex(dark))
    }

    /// A colour that follows light / dark mode: Platform.swift's
    /// `Color(light:dark:)`, made here because that file is the app's
    /// alone. It answers to the environment it is drawn in, so a view
    /// that sets its colour scheme (a Live Activity on its dark platter)
    /// gets the column it asks for.
    private static func pair(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(dark) : NSColor(light)
        })
        #endif
    }
}

/// The colour of a widget's title: Theme's `TitleInk` for the targets
/// that cannot see it. Half the tertiary grey, about 2:1 on the paper, by
/// the owner's choice for what is structure; the whole of it with Increase
/// Contrast.
struct WidgetTitleInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        AnyShapeStyle(WidgetPalette.textTertiary.opacity(environment.colorSchemeContrast == .increased ? 1 : 0.5))
    }
}
