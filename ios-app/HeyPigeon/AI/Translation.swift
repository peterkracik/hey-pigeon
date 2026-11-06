// Translating a selection of a received message (Features/Thread/
// TranslationPanel.swift): the instruction the engine's edit endpoint gets
// (the core's `ai_edit_text` wraps it in the edit system prompt and picks
// the provider; no second AI door), which language it asks for, and where
// the translate circle sits beside a selection. Pure Foundation, so the
// language and placement rules are tested without a view or a model.

import Foundation

/// The translation request as the AI provider sees it, and the target
/// language choices Settings never had to learn about.
enum Translation {
    /// Opening words of the instruction (MockEngine keys on them).
    static let instructionPrefix = "Translate the text into"

    /// UserDefaults key for the last language picked in the panel. Device
    /// local on purpose: a Mac and a phone in different languages each
    /// keep their own.
    static let languageKey = "translation.language"

    /// The instruction `ai_edit_text` runs: the edit system prompt already
    /// says "apply the instruction to the text and return only the revised
    /// text", so this only has to say what a good translation keeps.
    static func instruction(to language: String) -> String {
        "\(instructionPrefix) \(language). Keep the meaning, tone, names, numbers, dates, links and the line "
            + "breaks; translate greetings and sign-offs too. If the text is already in \(language), return it "
            + "unchanged. Return only the translation, nothing else."
    }

    /// The English name of a language code ("sk" → "Slovak"): the model
    /// reads the instruction in English, whatever the device speaks.
    static func languageName(for code: String) -> String? {
        let base = Locale(identifier: code).language.languageCode?.identifier ?? code
        guard let name = Locale(identifier: "en").localizedString(forLanguageCode: base), !name.isEmpty else { return nil }
        return name
    }

    /// The language the device is set to, or English.
    static var deviceLanguage: String {
        Locale.preferredLanguages.first.flatMap(languageName(for:)) ?? "English"
    }

    /// Languages a translation can go to: the device's preferred ones
    /// first (what the user reads), then the common set, no repeats. Whatever
    /// was picked last is in the list even when it is none of these.
    static func choices(preferred codes: [String] = Locale.preferredLanguages, picked: String? = nil) -> [String] {
        var out: [String] = []
        let candidates = codes.compactMap(languageName(for:)) + [picked].compactMap({ $0 }) + common
        for name in candidates where !out.contains(name) {
            out.append(name)
        }
        return out
    }

    /// The common set, in the order they are offered after the device's.
    static let common = [
        "English", "Spanish", "French", "German", "Italian", "Portuguese", "Dutch", "Polish", "Czech", "Slovak",
        "Ukrainian", "Russian", "Turkish", "Arabic", "Hindi", "Chinese", "Japanese", "Korean",
    ]

    /// A selection longer than this is cut before it goes to the provider:
    /// the panel is for a paragraph or a page, and the on-device model's
    /// window is short (ModelProviders, `promptBudget`).
    static let maxCharacters = 6_000

    /// The selection as sent: trimmed and cut to `maxCharacters` on a word.
    static func prepared(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count > maxCharacters else { return t }
        let cut = String(t.prefix(maxCharacters))
        if let space = cut.lastIndex(where: { $0.isWhitespace }), cut.distance(from: cut.startIndex, to: space) > maxCharacters / 2 {
            return String(cut[..<space])
        }
        return cut
    }
}

/// A selected range of a message body, as the native text view or the web
/// view reports it: the text, and where it ends in that view's coordinates
/// (the trailing edge of its last line, its full rect), so the translate
/// circle can sit beside it.
struct BodySelection: Equatable {
    let text: String
    /// Union of the selection's line rects, in the reporting view's coordinates.
    let rect: CGRect
    /// The trailing edge of the last selected line (where the end handle is).
    let end: CGPoint
    /// Height of that last line.
    let lineHeight: CGFloat

    /// Whether there is something worth translating (not just whitespace).
    var isUsable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(text: String, rect: CGRect, end: CGPoint, lineHeight: CGFloat) {
        self.text = text
        self.rect = rect
        self.end = end
        self.lineHeight = lineHeight
    }

    /// The web view's report (MessageBodyView's selection script): `text`,
    /// the rect as `x y width height`, the end as `endX endY lineHeight`,
    /// all CSS pixels, which are the view's points. Nil for null (nothing
    /// selected) or a report missing its text.
    init?(message: [String: Any]?) {
        guard let m = message, let text = m["text"] as? String else { return nil }
        func number(_ key: String) -> CGFloat { CGFloat((m[key] as? NSNumber)?.doubleValue ?? 0) }
        self.init(text: text,
                  rect: CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height")),
                  end: CGPoint(x: number("endX"), y: number("endY")),
                  lineHeight: max(number("lineHeight"), 1))
    }
}

/// Where the translate circle goes for a selection: beside the end of the
/// last selected line, on its right when there is room, else under it.
/// Never over the selection itself, and never past the view's edges, so a
/// selection ending at the right margin still gets its circle on screen.
enum SelectionBadgeGeometry {
    /// The circle's diameter, in points.
    static let size: CGFloat = 32
    /// Breathing room between the selection's end handle and the circle.
    static let gap: CGFloat = 14

    /// The circle's centre for a selection in a view `width` points wide.
    static func center(for s: BodySelection, width: CGFloat) -> CGPoint {
        let half = size / 2
        let right = s.end.x + gap + half
        if right + half <= width {
            return CGPoint(x: right, y: s.end.y)
        }
        // No room on the right: under the last line, pulled in from the edge.
        let x = min(max(s.end.x, half), max(width - half, half))
        return CGPoint(x: x, y: s.end.y + s.lineHeight / 2 + gap / 2 + half)
    }
}
