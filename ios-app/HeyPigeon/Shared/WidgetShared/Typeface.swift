// The app's two typefaces. Instrument Sans carries the interface: names,
// titles, rows, buttons. DM Mono is for what is read as data: times,
// counts, sizes, tags, keys and the titles of groups and sections. Mail
// itself stays in the system font (a message's HTML is shown as it came).
//
// The files are in HeyPigeon/Resources/Fonts with their licences (both
// families are under the SIL Open Font License) and each bundle names
// them in its Info.plist (project.yml: UIAppFonts on iOS,
// ATSApplicationFontsPath on the Mac). This file is compiled into the
// app, the widgets and the share extension, so all of them set type the
// same way; `Theme` forwards here for the app's views.
//
// A weight is a face of its own, asked for by name: `.weight()` and
// `.bold()` on a custom font do not reliably pick the family's heavier
// file, so every call says which weight it wants. Should a bundle ever
// lack the files, the system font takes over at the same size and
// weight (checked once, as CoreText would otherwise be asked for the
// missing face on every row).

import CoreText
import SwiftUI

enum Typeface {
    /// Both families are in this bundle.
    static let isBundled = hasFace("InstrumentSans-Regular") && hasFace("DMMono-Regular")

    // MARK: Instrument Sans

    /// Interface text at a text style's size; it scales with Dynamic Type.
    static func sans(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        guard isBundled else { return .system(style, weight: weight) }
        return .custom(sansFace(weight), size: size(of: style), relativeTo: style)
    }

    /// Interface text at a size of its own: scaled like `style` when one
    /// is given, fixed otherwise (the Mac's window, a badge).
    static func sans(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil) -> Font {
        guard isBundled else {
            if let style { return .system(style, weight: weight) }
            return .system(size: size, weight: weight)
        }
        if let style { return .custom(sansFace(weight), size: size, relativeTo: style) }
        return .custom(sansFace(weight), fixedSize: size)
    }

    // MARK: DM Mono

    /// Data (a time, a count, a tag) at a text style's size.
    static func mono(_ style: Font.TextStyle, _ weight: Font.Weight = .regular) -> Font {
        guard isBundled else { return .system(style, design: .monospaced, weight: weight) }
        return .custom(monoFace(weight), size: size(of: style), relativeTo: style)
    }

    /// Data at a size of its own: scaled like `style` when one is given,
    /// fixed otherwise.
    static func mono(size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle? = nil) -> Font {
        guard isBundled else {
            if let style { return .system(style, design: .monospaced, weight: weight) }
            return .system(size: size, weight: weight, design: .monospaced)
        }
        if let style { return .custom(monoFace(weight), size: size, relativeTo: style) }
        return .custom(monoFace(weight), fixedSize: size)
    }

    // MARK: Faces and sizes

    /// The family has four weights; anything heavier than bold is bold,
    /// anything lighter than medium is regular.
    private static func sansFace(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium: "InstrumentSans-Medium"
        case .semibold: "InstrumentSans-SemiBold"
        case .bold, .heavy, .black: "InstrumentSans-Bold"
        default: "InstrumentSans-Regular"
        }
    }

    /// The mono has two weights in the bundle: regular, and medium for
    /// anything that asks for emphasis.
    private static func monoFace(_ weight: Font.Weight) -> String {
        switch weight {
        case .medium, .semibold, .bold, .heavy, .black: "DMMono-Medium"
        default: "DMMono-Regular"
        }
    }

    /// A text style's size at the default setting, which is what a custom
    /// font is scaled from: the system's own table, the phone's and the
    /// Mac's.
    private static func size(of style: Font.TextStyle) -> CGFloat {
        #if os(macOS)
        switch style {
        case .largeTitle: 26
        case .title: 22
        case .title2: 17
        case .title3: 15
        case .headline, .body: 13
        case .callout: 12
        case .subheadline: 11
        default: 10
        }
        #else
        switch style {
        case .largeTitle: 34
        case .title: 28
        case .title2: 22
        case .title3: 20
        case .headline, .body: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 13
        case .caption: 12
        default: 11
        }
        #endif
    }

    /// CoreText answers a name it does not know with a fallback font, so
    /// the test is the name of what came back.
    private static func hasFace(_ name: String) -> Bool {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == name
    }
}
