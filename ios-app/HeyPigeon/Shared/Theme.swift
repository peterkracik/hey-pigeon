// Design tokens, ported from desktop-app/src/styles/{colors,typography}.css.
// Light/dark follow the system; the navy scale is the same in both, the
// surfaces flip.

import SwiftUI

enum Theme {
    // Navy scale
    static let navy950 = Color(hex: 0x0B0D12)
    static let navy900 = Color(hex: 0x111318)
    static let navy800 = Color(hex: 0x1D2027)
    static let navy700 = Color(hex: 0x33363E)
    static let navy500 = Color(hex: 0x75787F)
    static let navy400 = Color(hex: 0x9A9CA2)
    static let navy200 = Color(hex: 0xDEDFE2)
    static let navy100 = Color(hex: 0xEEEEF0)
    static let navy50 = Color(hex: 0xF7F7F8)

    /// The one accent: pink. Used for the archive gesture and highlights.
    static let accent = Color(hex: 0xEE4D9B)
    static let accentSoft = Color(hex: 0xEE4D9B).opacity(0.13)

    // Dark surfaces are a dark grey, not near-black: the canvas lifts off
    // the OLED black of the status bar and the glass bars still read.
    // Dark: a warm dark grey, canvas and card a small step apart.
    static let canvas = Color(light: Color(hex: 0xFBFBFB), dark: Color(hex: 0x1C1B1E))
    static let card = Color(light: .white, dark: Color(hex: 0x232226))
    /// Sunken blocks (summaries, chips, inputs): the desktop's --surface-sunken.
    static let sunken = Color(light: navy100, dark: Color(hex: 0x2E2D31))
    static let textPrimary = Color(light: Color(hex: 0x0D0D10), dark: navy50)
    /// Text on a textPrimary-tinted surface (the Send pill).
    static let onPrimary = Color(light: .white, dark: Color(hex: 0x1A1C22))
    static let textSecondary = Color(light: Color(hex: 0x4E5057), dark: navy400)
    static let textTertiary = Color(light: Color(hex: 0x8E9096), dark: navy500)
    static let separator = Color(light: Color(hex: 0xE4E4E7), dark: Color(hex: 0x343338))
    /// Something went wrong and wants a look (a change that was not
    /// sent). Not the accent: pink is the colour of done.
    static let warning = Color(light: Color(hex: 0xB34E2E), dark: Color(hex: 0xF0916F))
    /// The row of the thread open beside the list (the iPad's columns).
    /// Not `sunken`: that is the label chips' fill, and they vanished on it.
    static let rowOpen = Color(light: Color(hex: 0xE8EBF3), dark: Color(hex: 0x2B2F3B))
    /// Unread rows sit on the card surface; read rows sink into the canvas.
    static let rowUnread = card
    static let rowRead = canvas
    /// Unread marker on the row's left edge: white on dark, the accent on light.
    static let unreadBar = Color(light: accent, dark: .white)
    /// Pin colour (Gmail star): the amber tag.
    static let pin = Color(hex: 0xE3B341)

    /// The tag surfaces, made once: `Color(light:dark:)` builds a dynamic
    /// platform colour each call, and every row's chips asked for theirs on
    /// each render.
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
    static let dangerText = Color(light: tagForeground(.coral), dark: Color(hex: 0xE8907A))
    /// Need reply as a solid colour (its swipe panel, the Mac row's chip):
    /// the sky tag's foreground.
    static let needReply = tagForeground(.sky)
    /// The Pin swipe panel: the amber tag's foreground, dark enough to
    /// carry white text (`pin` is the lighter amber of the mark itself).
    static let pinStrong = tagForeground(.amber)

    static func priorityColor(_ p: TriageLevel) -> Color {
        switch p {
        case .high: Color(hex: 0xB34E2E)
        case .medium: Color(hex: 0xA9761E)
        case .low: navy400
        case .spam: navy200
        }
    }

    // Typography: Manrope for display (brand), system for body (legibility,
    // Dynamic Type). Every size is relative to a text style so it scales.
    // The brand files are dropped into the bundle by hand (README); without
    // them SwiftUI fell back to the regular system font and asked CoreText
    // for the missing face on every row. Checked once here instead, and the
    // fallback keeps the weight at the text style's own size.
    private static let hasManrope = PlatformFont(name: "Manrope-Bold", size: 12) != nil

    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        hasManrope ? .custom("Manrope-ExtraBold", size: size, relativeTo: style) : .system(style, weight: .heavy)
    }

    static func sender(_ unread: Bool) -> Font {
        hasManrope
            ? .custom(unread ? "Manrope-Bold" : "Manrope-SemiBold", size: 14, relativeTo: .subheadline)
            : .system(.subheadline, weight: unread ? .bold : .semibold)
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

/// The menu sheets (sidebar, Settings): the app's canvas, sections on
/// cards, close in the nav bar — one look for both.
extension View {
    func menuList() -> some View {
        groupedListStyle()
            .menuSectionSpacing()
            // The inset-grouped default leaves a wide gutter in a sheet; keep
            // the cards close to the edges like the inbox rows.
            .contentMargins(.horizontal, 12, for: .scrollContent)
            .contentMargins(.top, 4, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
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

    /// The gap between the cards; an iOS-only modifier (the Mac's inset
    /// list spaces its sections itself).
    @ViewBuilder
    func menuSectionSpacing() -> some View {
        #if os(iOS)
        listSectionSpacing(16)
        #else
        self
        #endif
    }

    /// A section of a menu sheet, on a card. On the Mac the grouped form
    /// draws its own boxes, so the row background is left to it.
    @ViewBuilder
    func menuCard() -> some View {
        #if os(iOS)
        listRowBackground(Theme.card)
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

    /// The menu sheets' presentation: full height on iOS; on the Mac a
    /// sheet is a window, so it gets a size instead.
    @ViewBuilder
    func menuSheet() -> some View {
        #if os(iOS)
        presentationBackground(Theme.canvas)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        #else
        frame(minWidth: 480, idealWidth: 600, minHeight: 420, idealHeight: 760)
            .background(Theme.canvas)
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
/// bundle): the title in the display face, what the sheet is about under
/// it, and the close button. It is the first section's header. The close
/// is the app's pill (`pillButton`: the phone's glass circle; a glass
/// button on the Mac is a bordered white box) and takes Esc.
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let close: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.display(22, relativeTo: .title2)).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(Theme.textTertiary).lineLimit(1)
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

/// Settings' container: the phone's menu list; on the Mac a grouped form,
/// the boxed sections of System Settings, with no scroll bar.
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
