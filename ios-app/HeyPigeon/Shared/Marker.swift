// The pieces of the look that more than one screen draws
// (docs/specs/marker-look.md): the title of a group or a section, the
// highlighter, a tag written as a word, a rule, and the two capsule
// buttons. The colours and the type are Theme's; these are the shapes.

import SwiftUI

/// The title of a group of rows or of a section: its name in small mono
/// capitals, a rule that fills the rest of the line, a count at the far
/// end when there is one — all in `Theme.titleInk`, the light grey of
/// structure. A glyph before the name (the AI's sparkle) keeps its own
/// colour, and so does a control placed after the rule (`accessory`:
/// "Clear", a language menu), which is something to press, not structure.
struct SectionTitle<Accessory: View>: View {
    let title: String
    var count: String? = nil
    var systemImage: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.pinkInk)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(Theme.label)
                    .tracking(Theme.labelTracking)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.titleInk)
                    .lineLimit(1)
            }
            Rectangle().fill(Theme.titleInk).frame(height: 1)
            if let count {
                Text(count).font(Theme.label).foregroundStyle(Theme.titleInk).lineLimit(1)
            }
            accessory()
        }
        .accessibilityAddTraits(.isHeader)
    }
}

extension SectionTitle where Accessory == EmptyView {
    init(_ title: String, count: String? = nil, systemImage: String? = nil) {
        self.init(title: title, count: count, systemImage: systemImage) { EmptyView() }
    }

    /// A title with how many rows stand under it.
    init(_ title: String, count: Int, systemImage: String? = nil) {
        self.init(title: title, count: String(count), systemImage: systemImage) { EmptyView() }
    }
}

/// The rule that opens a section which has no name.
struct SectionRule: View {
    var body: some View {
        Rectangle().fill(Theme.titleInk).frame(height: 1).accessibilityHidden(true)
    }
}

/// The hairline between two rows.
struct RowRule: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).accessibilityHidden(true)
    }
}

/// A label written as a word in the margin, not boxed as a chip:
/// `#Travel`, in the mono.
struct TagText: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        Text("#\(name)").font(Theme.tag).foregroundStyle(Theme.textSecondary).lineLimit(1)
    }
}

/// A state said in its colour, as a glyph and a few words in the mono
/// ("Need reply", a reminder's time): writing on the paper, never a
/// filled chip. `tint` is `Theme.state(_:)`, or `Theme.pinkInk` for what
/// the AI suggests.
struct StateMark: View {
    var text: String? = nil
    var systemImage: String? = nil
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            if let text, !text.isEmpty { Text(text).font(Theme.tag).lineLimit(1) }
        }
        .foregroundStyle(tint)
    }
}

extension View {
    /// The highlighter: a band of `Theme.marker` behind the lower half of
    /// a line of text, a little wider than the words, as a marker pen
    /// leaves it. It means "look here" and nothing else: an unread
    /// sender, an action the AI suggests. The band is the text's own
    /// background scaled down towards its baseline, so it follows the
    /// text at any size; the padding it adds at the sides is taken back,
    /// and the words stay where they were.
    func marker(_ on: Bool = true) -> some View {
        padding(.horizontal, 3)
            .background {
                if on {
                    Theme.marker.scaleEffect(x: 1, y: 0.42, anchor: UnitPoint(x: 0.5, y: 0.862))
                }
            }
            .padding(.horizontal, -3)
    }

    /// A word struck through: what is done.
    func struckThrough(_ on: Bool = true) -> some View {
        strikethrough(on, color: Theme.textTertiary)
    }
}

/// The primary action of a screen where the system's prominent glass
/// button is not what is wanted (a row of choices in a sheet, the Mac's
/// panels): an ink capsule with the paper's colour for its words. One
/// per screen.
struct InkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(.subheadline, .semibold))
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Theme.textPrimary, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(Capsule())
    }
}

/// Every other capsule button: the ink as a hairline outline, the paper
/// showing through.
struct OutlineButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(.subheadline, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().strokeBorder(Theme.textPrimary, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .contentShape(Capsule())
    }
}
