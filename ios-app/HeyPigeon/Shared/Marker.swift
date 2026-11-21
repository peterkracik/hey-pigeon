// The pieces of the look that more than one screen draws
// (docs/specs/marker-look.md): the title of a group or a section, the
// highlighter, a tag written as a word, a rule, and the two capsule
// buttons. The colours and the type are Theme's; these are the shapes.

import SwiftUI

/// The title of a group of rows or of a section: its name in small mono
/// capitals, a rule that fills the rest of the line, a count at the far
/// end when there is one. The words are `Theme.titleInk`, the light grey
/// of structure, and the rule `Theme.titleRule`, as faint as the lines
/// between rows. A glyph before the name (the AI's sparkle) keeps its own
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
            Rectangle().fill(Theme.titleRule).frame(height: 1)
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
        Rectangle().fill(Theme.titleRule).frame(height: 1).accessibilityHidden(true)
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
    /// Medium where the state is the row's news ("Not sent"); regular
    /// where it only accompanies it.
    var weight: Font.Weight = .regular

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)).accessibilityHidden(true)
            }
            if let text, !text.isEmpty { Text(text).font(font).lineLimit(1) }
        }
        .foregroundStyle(tint)
    }

    /// `Theme.tag` at this mark's weight (the sizes are that token's).
    private var font: Font {
        #if os(macOS)
        return Theme.mono(size: 11, weight: weight)
        #else
        return Theme.mono(size: 11.5, weight: weight, relativeTo: .caption)
        #endif
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

    /// Unread, on a mail row: a small pink triangle in the row's bottom
    /// leading corner, with the sender in bold. It took the place of the
    /// highlighter behind the sender's name (the owner's choice, on the
    /// canvas page "Marker: edge to edge, pink corner"). Goes on the
    /// row's whole surface, so the corner is the row's own.
    func unreadCorner(_ on: Bool) -> some View {
        overlay(alignment: .bottomLeading) {
            if on {
                UnreadCorner().fill(Theme.accent).frame(width: 10, height: 10)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }

    /// A word struck through: what is done.
    func struckThrough(_ on: Bool = true) -> some View {
        strikethrough(on, color: Theme.textTertiary)
    }
}

/// The right-angled triangle of `unreadCorner`: its right angle in the
/// bottom leading corner.
struct UnreadCorner: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
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
/// showing through. `compact` is the small one at the end of a row
/// (Unblock, Forget, Send again): a size down and tighter, so the row
/// keeps the height of its neighbours.
struct OutlineButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    /// Spelled out: with a private member the synthesized initialiser
    /// is private too, and other files build this style.
    init(compact: Bool = false) {
        self.compact = compact
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.sans(compact ? .footnote : .subheadline, .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 6 : 9)
            .background(Capsule().strokeBorder(Theme.textPrimary, lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.35)
            .contentShape(Capsule())
    }
}
