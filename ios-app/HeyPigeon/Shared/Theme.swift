// Design tokens of the app's look: paper, ink and one pink highlighter
// (docs/specs/marker-look.md). Light and dark follow the system. Structure
// is quiet (hairlines, light grey titles), content and actions are ink,
// and pink only ever means "look here". The Mac window's own surfaces are
// MacTheme (macos-app MacStyle.swift); the typefaces are Typeface
// (Shared/WidgetShared), forwarded here for the app's views.

import SwiftUI

enum Theme {
    // The grey scale the first client's tokens came with. A few callers
    // still name a step (the priority bars); new code uses the roles below.
    static let navy950 = Color(hex: 0x0B0D12)
    static let navy900 = Color(hex: 0x111318)
    static let navy800 = Color(hex: 0x1D2027)
    static let navy700 = Color(hex: 0x33363E)
    static let navy500 = Color(hex: 0x75787F)
    static let navy400 = Color(hex: 0x9A9CA2)
    static let navy200 = Color(hex: 0xDEDFE2)
    static let navy100 = Color(hex: 0xEEEEF0)
    static let navy50 = Color(hex: 0xF7F7F8)

    // MARK: Pink

    /// The pink as a fill: the AI's own button (the draft circle), the
    /// progress of an analysis. Never a row's or a title's colour: as a
    /// mark it is `marker`, as writing `pinkInk`.
    static let accent = Color(hex: 0xEE4D9B)
    static let accentSoft = Color(hex: 0xEE4D9B).opacity(0.13)
    /// The highlighter: a band behind a word that says "look here" — an
    /// unread sender, an action the AI suggests. Drawn by `marker()`.
    /// Half the pink on dark, where the pale band would glare.
    static let marker = Color(light: Color(hex: 0xFFC9E2), dark: Color(hex: 0xEE4D9B).opacity(0.5))
    /// Pink as writing or a glyph (the AI's sparkle, a suggestion's
    /// words): dark enough to read on the paper, light enough on dark.
    static let pinkInk = Color(light: Color(hex: 0xCC2277), dark: Color(hex: 0xF58BBE))
    /// Pink as writing on an ink fill (the toast's Undo): the marker's
    /// pale pink on light's dark ink, the dark pink on dark's light ink.
    static let onPrimaryPink = Color(light: Color(hex: 0xFFC9E2), dark: Color(hex: 0xCC2277))

    // MARK: Surfaces

    // Light is paper white with no step between a list and its rows: rows
    // are ruled, not carded. Dark is a dark grey a step off black, not
    // near-black: the canvas lifts off the OLED black of the status bar
    // and the glass bars still read.
    static let canvas = Color(light: .white, dark: Color(hex: 0x16181D))
    /// What was a row's or a section's card. It is the paper itself now
    /// (no step, no shadow); the name stays for the rows that fill
    /// themselves with it.
    static let card = canvas
    /// A surface that lies over the canvas: a sheet, a popover, a panel.
    /// The paper again on light; a step up on dark, where a sheet would
    /// otherwise merge with what it covers.
    static let raised = Color(light: .white, dark: Color(hex: 0x1E2026))
    /// The wash that lay behind a mail list is gone with the cards: a
    /// list stands on the flat paper. The names stay for their callers.
    static let washWarm = canvas
    static let washCool = canvas
    static let listWash = Wash(base: canvas, warm: washWarm, cool: washCool)
    /// Sunken blocks (a search field, a row under the pointer, a
    /// placeholder bar): the one grey step below the paper.
    static let sunken = Color(light: Color(hex: 0xF4F4F6), dark: Color(hex: 0x23262D))

    // MARK: Ink

    static let textPrimary = Color(light: Color(hex: 0x0B0D12), dark: Color(hex: 0xF3F4F6))
    /// Writing on an ink fill (the Send pill, a selected tab): the paper.
    static let onPrimary = Color(light: .white, dark: Color(hex: 0x16181D))
    static let textSecondary = Color(light: Color(hex: 0x454850), dark: Color(hex: 0xB6B9C0))
    /// The lightest grey that is still read: 5:1 on the paper, in both
    /// appearances (previews, times, footers).
    static let textTertiary = Color(light: Color(hex: 0x6B6E76), dark: Color(hex: 0x8B8E96))
    /// The rule between two rows.
    static let separator = Color(light: Color(hex: 0xE7E7EA), dark: Color(hex: 0x2B2E36))
    /// The outline of something boxed: a filter chip, a key, a text box.
    static let outline = Color(light: Color(hex: 0xC9CACF), dark: Color(hex: 0x3A3D45))
    /// The title of a group or a section, its rule and its count
    /// (`SectionTitle`): structure, so half the tertiary grey, and the
    /// whole of it with Increase Contrast.
    static let titleInk = TitleInk()
    /// A switch that is on: ink. On dark a light grey rather than the
    /// near-white ink, which the system's white knob would vanish into.
    static let switchOn = Color(light: Color(hex: 0x0B0D12), dark: Color(hex: 0xB6B9C0))
    /// Something went wrong and wants a look (a change that was not
    /// sent). Not pink: pink is "look here", not "this failed".
    static let warning = Color(light: Color(hex: 0xB34E2E), dark: Color(hex: 0xF0916F))
    /// The row of the thread open beside the list (the iPad's columns).
    static let rowOpen = sunken
    /// Read and unread rows stand on the same paper; what tells them
    /// apart is the sender (`marker()` and the weight).
    static let rowUnread = card
    static let rowRead = canvas
    /// The bar that marked an unread row's edge. Nothing draws it in
    /// this look; the name stays until its last caller is gone.
    static let unreadBar = Color.clear
    /// The pin's mark: ink, as every mark that is not a state is.
    static let pin = textPrimary

    // MARK: States

    /// A state as writing or a glyph on the paper (a reminder's clock,
    /// "Need reply", an account's dot): the tag's colour on light, a
    /// lighter step of it on dark, both readable as small text. For a
    /// fill that carries white text (a swipe panel) use `tagForeground`.
    private static let states: [AccountColor: Color] = Dictionary(
        uniqueKeysWithValues: AccountColor.allCases.map { ($0, makeState($0)) }
    )

    static func state(_ c: AccountColor) -> Color {
        states[c] ?? makeState(c)
    }

    private static func makeState(_ c: AccountColor) -> Color {
        switch c {
        case .coral: Color(light: Color(hex: 0xB34E2E), dark: Color(hex: 0xF0916F))
        case .mint: Color(light: Color(hex: 0x1F7A5C), dark: Color(hex: 0x5CC6A0))
        case .lavender: Color(light: Color(hex: 0x6A4FC4), dark: Color(hex: 0xA995F2))
        case .sky: Color(light: Color(hex: 0x2A6BAE), dark: Color(hex: 0x7FB2E8))
        case .amber: Color(light: Color(hex: 0xA9761E), dark: Color(hex: 0xE3B341))
        }
    }

    /// The tinted surfaces of the chips this look no longer draws
    /// (states are writing, not fills). Kept for the callers that still
    /// ask; made once: `Color(light:dark:)` builds a dynamic platform
    /// colour each call.
    private static let tagBackgrounds: [AccountColor: Color] = Dictionary(
        uniqueKeysWithValues: AccountColor.allCases.map { ($0, makeTagBackground($0)) }
    )

    static func tagBackground(_ c: AccountColor) -> Color {
        tagBackgrounds[c] ?? makeTagBackground(c)
    }

    private static func makeTagBackground(_ c: AccountColor) -> Color {
        switch c {
        case .coral: Color(light: Color(hex: 0xFBE2DA), dark: Color(hex: 0x4A2A22))
        case .mint: Color(light: Color(hex: 0xD9EFE6), dark: Color(hex: 0x1F3A30))
        case .lavender: Color(light: Color(hex: 0xE9E3FA), dark: Color(hex: 0x332A4A))
        case .sky: Color(light: Color(hex: 0xDDEAFB), dark: Color(hex: 0x1E2F45))
        case .amber: Color(light: Color(hex: 0xFBEBD3), dark: Color(hex: 0x4A3A1E))
        }
    }

    /// A tag's colour as a fill dark enough to carry white text, the same
    /// in both appearances (a swipe panel). As writing on the paper it is
    /// `state(_:)`, which has a dark pair.
    static func tagForeground(_ c: AccountColor) -> Color {
        switch c {
        case .coral: Color(hex: 0xB34E2E)
        case .mint: Color(hex: 0x1F7A5C)
        case .lavender: Color(hex: 0x6A4FC4)
        case .sky: Color(hex: 0x2A6BAE)
        case .amber: Color(hex: 0xA9761E)
        }
    }

    /// What deletes or went wrong (the Delete swipe and button, an error
    /// line): the coral tag's foreground. No new hue.
    static let danger = tagForeground(.coral)
    /// An error line as text (a failed sync, a rejected key). `danger` is
    /// dark enough to carry white text, which makes it too dim to read as
    /// small text on the dark surfaces: there the same coral, lighter.
    static let dangerText = Color(light: tagForeground(.coral), dark: Color(hex: 0xF0916F))
    /// Need reply as a solid colour (its swipe panel): the sky tag's
    /// foreground. As a mark on a row it is `state(.sky)`.
    static let needReply = tagForeground(.sky)
    /// The Pin swipe panel: the amber tag's foreground, dark enough to
    /// carry white text.
    static let pinStrong = tagForeground(.amber)

    static func priorityColor(_ p: TriageLevel) -> Color {
        switch p {
        case .high: Color(hex: 0xB34E2E)
        case .medium: Color(hex: 0xA9761E)
        case .low: navy400
        case .spam: navy200
        }
    }

    // MARK: Type

    // Instrument Sans for the interface, DM Mono for data (Typeface).
    // Every size on the phone is relative to a text style, so Dynamic
    // Type scales it; the Mac's window has sizes of its own. A weight is
    // an argument, never `.weight()` on the result: a custom font's
    // heavier face has to be asked for by name.

    /// Interface text at a text style's size.
    static func sans(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        Typeface.sans(style, weight)
    }

    /// Interface text at a size of its own: scaled like `style` when one
    /// is given, fixed otherwise.
    static func sans(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil) -> Font {
        Typeface.sans(size: size, weight: weight, relativeTo: style)
    }

    /// Data (a time, a count, a size, a key) at a text style's size.
    static func mono(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        Typeface.mono(style, weight)
    }

    /// Data at a size of its own: scaled like `style` when one is given,
    /// fixed otherwise.
    static func mono(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil) -> Font {
        Typeface.mono(size: size, weight: weight, relativeTo: style)
    }

    /// A title: a sheet's, a thread's subject, an empty state's.
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        Typeface.sans(size: size, weight: .bold, relativeTo: style)
    }

    /// A sender's name on a row: bold while unread (with `marker()`),
    /// medium once read.
    static func sender(_ unread: Bool) -> Font {
        #if os(macOS)
        return Typeface.sans(size: 13, weight: unread ? .bold : .medium)
        #else
        return Typeface.sans(size: 16, weight: unread ? .bold : .medium, relativeTo: .callout)
        #endif
    }

    /// The small text of a thread and of the Mac's rows, by what it is
    /// for. On iOS these are text style sizes (Dynamic Type). On the Mac
    /// those styles are 10 and 11 pt, a step under the window's list
    /// (MailRow: 13 for the names, subjects and snippets, 12 for the
    /// time, 11 for the chips), so a thread read smaller than the row it
    /// was opened from: the Mac takes the list's sizes instead.
    enum TextRole {
        /// A line of secondary text (a snippet, a label): `.footnote`; the Mac's 13.
        case secondary
        /// A time or a count, in the mono: `.footnote`'s place; 12 on both.
        case meta
        /// The finest line (who a message went to): `.caption`; the Mac's 12.
        case caption
        /// A size beside a caption: `.caption2`; the Mac's 11.
        case caption2
        /// A short text to read (a draft's first lines): `.subheadline`; the Mac's 13.
        case bodySmall
    }

    /// A role's font at a weight (`Theme.text(.secondary, .semibold)`).
    static func text(_ role: TextRole, _ weight: Font.Weight = .regular) -> Font {
        switch role {
        case .secondary: macOr(13, .footnote, weight)
        case .meta: Typeface.mono(size: 12, weight: weight, relativeTo: metaStyle)
        case .caption: macOr(12, .caption, weight)
        case .caption2: macOr(11, .caption2, weight)
        case .bodySmall: macOr(13, .subheadline, weight)
        }
    }

    /// The font that sizes an SF Symbol standing beside text of a role:
    /// the system's own at the role's size. A symbol takes its weight
    /// from a system font; set on one of the faces above, `.semibold`
    /// would be asked of a file that is only ever regular.
    static func glyph(_ role: TextRole, _ weight: Font.Weight = .regular) -> Font {
        switch role {
        case .secondary: systemMacOr(13, .footnote, weight)
        case .meta: systemMacOr(12, .footnote, weight)
        case .caption: systemMacOr(12, .caption, weight)
        case .caption2: systemMacOr(11, .caption2, weight)
        case .bodySmall: systemMacOr(13, .subheadline, weight)
        }
    }

    static var secondary: Font { text(.secondary) }
    static var meta: Font { text(.meta) }
    static var caption: Font { text(.caption) }
    static var caption2: Font { text(.caption2) }
    static var bodySmall: Font { text(.bodySmall) }

    /// The title of a group or a section (`SectionTitle`): small mono
    /// capitals, spaced by `labelTracking`.
    static var label: Font {
        #if os(macOS)
        return Typeface.mono(size: 10.5, weight: .medium)
        #else
        return Typeface.mono(size: 11, weight: .medium, relativeTo: .caption2)
        #endif
    }

    /// The letter-spacing of `label` (0.08 em of its 11 pt).
    static let labelTracking: CGFloat = 0.9

    /// A tag written as a word (`#Travel`), a state mark's words.
    static var tag: Font {
        #if os(macOS)
        return Typeface.mono(size: 11)
        #else
        return Typeface.mono(size: 11.5, relativeTo: .caption)
        #endif
    }

    /// The text style `meta` scales with on the phone; nil on the Mac,
    /// whose window does not scale.
    private static var metaStyle: Font.TextStyle? {
        #if os(macOS)
        return nil
        #else
        return .footnote
        #endif
    }

    private static func systemMacOr(_ size: CGFloat, _ style: Font.TextStyle, _ weight: Font.Weight) -> Font {
        #if os(macOS)
        return .system(size: size, weight: weight)
        #else
        return .system(style, weight: weight)
        #endif
    }

    private static func macOr(_ size: CGFloat, _ style: Font.TextStyle, _ weight: Font.Weight) -> Font {
        #if os(macOS)
        return Typeface.sans(size: size, weight: weight)
        #else
        return Typeface.sans(style, weight)
        #endif
    }
}

/// The colour of a section's or a group's title, of its rule and of its
/// count. They are structure, so they stand back: half the tertiary
/// grey, about 2:1 on the paper. A day group's title repeats what each
/// row's own date says; where a title is the only name of its group
/// (Settings, the folders) that is thin for some eyes, so with Increase
/// Contrast it is the whole tertiary grey.
struct TitleInk: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        AnyShapeStyle(Theme.textTertiary.opacity(environment.colorSchemeContrast == .increased ? 1 : 0.5))
    }
}

/// A list's background as a gradient along the diagonal: `warm` in the
/// top leading corner, `cool` in the bottom trailing one, `base` through
/// the middle. It was the trace of light behind the carded lists; in the
/// paper look all three are the same white, so it draws flat, and the
/// type stays for the places that still pass a wash
/// (`.background(Theme.listWash)`). With Increase Contrast it is `base`.
struct Wash: ShapeStyle {
    let base: Color
    let warm: Color
    let cool: Color

    func resolve(in environment: EnvironmentValues) -> AnyShapeStyle {
        guard environment.colorSchemeContrast != .increased else { return AnyShapeStyle(base) }
        return AnyShapeStyle(LinearGradient(
            stops: [
                Gradient.Stop(color: warm, location: 0),
                Gradient.Stop(color: base, location: 0.48),
                Gradient.Stop(color: base, location: 0.52),
                Gradient.Stop(color: cool, location: 1),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
    }
}

extension Color {
    /// `0xRRGGBB`, sRGB, opaque. The light/dark pair is `Color(light:dark:)`
    /// in Platform.swift.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// The menu sheets (sidebar, Settings): the raised paper, each section
/// under its title (`SectionTitle`) with hairlines between its rows and
/// no card around them, close in the nav bar — one look for both.
extension View {
    func menuList() -> some View {
        groupedListStyle()
            .menuSectionSpacing()
            // The inset-grouped default leaves a wide gutter in a sheet; keep
            // the rows close to the edges like the inbox's.
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Theme.raised)
    }

    /// Inset-grouped on iOS / iPadOS; the Mac has no inset-grouped list,
    /// and its plain inset style is the nearest.
    @ViewBuilder
    func groupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// The gap between the sections; an iOS-only modifier (the Mac's
    /// inset list spaces its sections itself).
    @ViewBuilder
    func menuSectionSpacing() -> some View {
        #if os(iOS)
        listSectionSpacing(16)
        #else
        self
        #endif
    }

    /// A section of a menu sheet: its rows straight on the sheet's paper
    /// (the grouped list's card is cleared away) with the app's hairline
    /// between them. The name is from when a section was a card. On the
    /// Mac the grouped form lays its sections out itself.
    @ViewBuilder
    func menuCard() -> some View {
        #if os(iOS)
        listRowBackground(Color.clear).listRowSeparatorTint(Theme.separator)
        #else
        self
        #endif
    }

    /// A screen presented with `coverScreen`: the canvas behind it on iOS
    /// (a cover has no detents); on the Mac the menu sheets' window size.
    @ViewBuilder
    func coverContent() -> some View {
        #if os(iOS)
        background(Theme.canvas)
        #else
        frame(minWidth: 480, idealWidth: 600, minHeight: 420, idealHeight: 760)
            .background(Theme.canvas)
        #endif
    }

    /// The menu sheets' presentation: full height on iOS, on the raised
    /// paper; on the Mac a sheet is a window, so it gets a size instead.
    @ViewBuilder
    func menuSheet() -> some View {
        #if os(iOS)
        presentationBackground(Theme.raised)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #else
        frame(minWidth: 480, idealWidth: 600, minHeight: 420, idealHeight: 760)
            .background(Theme.raised)
        #endif
    }
}

extension View {
    /// The sheet's close button in the bar. On the Mac Settings is a page
    /// of the window, not a sheet, and its toolbar is the window's: it
    /// leaves through the window's Back and Esc instead.
    @ViewBuilder
    func sheetCloseButton(_ close: @escaping () -> Void) -> some View {
        #if os(iOS)
        toolbar {
            ToolbarItem(placement: .barTrailing) {
                Button(role: .close) { close() }
            }
        }
        #else
        self
        #endif
    }
}

/// The title row of a sheet that has no navigation bar (Remind me, Add to
/// bundle): the title in the display face, drawn a little tight, what
/// the sheet is about under it, and the close button. It is the first section's header. The close
/// is the app's pill (`pillButton`: the phone's glass circle; a glass
/// button on the Mac is a bordered white box) and takes Esc.
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.display(24, relativeTo: .title2)).tracking(-0.4)
                    .foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(Theme.sans(.subheadline)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }
                .pillButton()
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
        }
        .textCase(nil)
        .padding(.bottom, 6)
    }
}

/// Settings' container: the phone's menu list; on the Mac a grouped form
/// with no scroll bar.
struct SettingsList<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(iOS)
        List { content() }.menuList()
        #else
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.never)
            .background(Theme.canvas)
        #endif
    }
}

/// Settings › Appearance: follow the system, or force light / dark.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
