// The few colours a widget needs, by the account colour's raw name, so the
// widget extension does not depend on Theme.swift (which needs the app's
// model types). Same hex values as Theme.tagForeground / Theme.accent.

import SwiftUI

enum WidgetPalette {
    static let accent = Color(red: 0xEE / 255, green: 0x4D / 255, blue: 0x9B / 255)
    static let needReply = Color(red: 0x2A / 255, green: 0x6B / 255, blue: 0xAE / 255)
    static let reminder = Color(red: 0x6A / 255, green: 0x4F / 255, blue: 0xC4 / 255)

    static func account(_ raw: String) -> Color {
        switch raw {
        case "coral": Color(red: 0xB3 / 255, green: 0x4E / 255, blue: 0x2E / 255)
        case "mint": Color(red: 0x1F / 255, green: 0x7A / 255, blue: 0x5C / 255)
        case "lavender": Color(red: 0x6A / 255, green: 0x4F / 255, blue: 0xC4 / 255)
        case "amber": Color(red: 0xA9 / 255, green: 0x76 / 255, blue: 0x1E / 255)
        default: Color(red: 0x2A / 255, green: 0x6B / 255, blue: 0xAE / 255) // sky
        }
    }
}
