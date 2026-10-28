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

    static let canvas = Color(light: Color(hex: 0xFBFBFB), dark: navy950)
    static let card = Color(light: .white, dark: navy900)
    static let textPrimary = Color(light: Color(hex: 0x0D0D10), dark: navy50)
    static let textSecondary = Color(light: Color(hex: 0x4E5057), dark: navy400)
    static let textTertiary = Color(light: Color(hex: 0x8E9096), dark: navy500)
    static let separator = Color(light: Color(hex: 0xE4E4E7), dark: navy800)

    static func tagBackground(_ c: AccountColor) -> Color {
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
    static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("Manrope-ExtraBold", size: size, relativeTo: style)
    }

    static func sender(_ unread: Bool) -> Font {
        .custom(unread ? "Manrope-Bold" : "Manrope-Medium", size: 16, relativeTo: .body)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

enum Haptics {
    static func archive() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}
