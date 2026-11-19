// Translating a selection of a received message (Features/Thread/
// TranslationPanel.swift): which language it asks for, which language the
// passage is in, how a long passage is cut into parts a model can hold,
// the check that an answer really left the source language, and where the
// translate circle sits beside a selection. Apple's translation answers
// first (AI/SystemTranslator.swift); what it cannot do goes to the
// engine's `ai_translate`, which has its own instruction. It used to go
// through the edit call, whose prompt said "the sender's own draft, keep
// its language": the answer came back in two languages. Foundation and
// NaturalLanguage only, so the rules are tested without a view or a model.

import Foundation
import NaturalLanguage

/// The translation request as the AI provider sees it, and the target
/// language choices Settings never had to learn about.
enum Translation {
    /// UserDefaults key for the last language picked in the panel. Device
    /// local on purpose: a Mac and a phone in different languages each
    /// keep their own.
    static let languageKey = "translation.language"

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

    /// The language code of an English language name ("Slovak" → "sk"),
    /// the reverse of `languageName(for:)`: the panel keeps names, Apple's
    /// translation and the language check want codes.
    static func code(for name: String) -> String? { codes[name] }

    /// Every ISO language by its English name, the shortest code winning
    /// ("sk" over "slk"). Built once.
    private static let codes: [String: String] = {
        var out: [String: String] = [:]
        for code in Locale.LanguageCode.isoLanguageCodes.map(\.identifier) {
            guard let name = Locale(identifier: "en").localizedString(forLanguageCode: code), !name.isEmpty else { continue }
            if let have = out[name], have.count <= code.count { continue }
            out[name] = code
        }
        return out
    }()

    /// The language part of a code ("pt-BR" → "pt", "zh-Hans" → "zh").
    static func base(_ code: String) -> String {
        Locale.Language(identifier: code).languageCode?.identifier ?? code
    }

    /// Whether two codes name the same language, whatever the region.
    static func same(_ a: String, _ b: String) -> Bool { base(a) == base(b) }

    /// The language a passage is written in, as a code, or nil when it is
    /// too short or too mixed to say with `atLeast` that much confidence.
    /// On device (NaturalLanguage).
    static func detectedLanguage(of text: String, atLeast confidence: Double = 0.6) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2_000)))
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= confidence else { return nil }
        return best.key.rawValue
    }

    /// Whether a translation still has a paragraph in the source language:
    /// what a small model does to a long passage. Only paragraphs long
    /// enough to tell are judged, and nothing is said without both codes.
    static func leftInSource(_ output: String, source: String?, target: String?) -> Bool {
        guard let source, let target, !same(source, target) else { return false }
        return paragraphs(output).contains { paragraph in
            guard paragraph.count >= 40, let got = detectedLanguage(of: paragraph) else { return false }
            return same(got, source)
        }
    }

    /// What one request to the on-device model carries: a passage and its
    /// translation have to fit a window of about 4,000 tokens together
    /// with the instruction, and a small model handed more than a few
    /// paragraphs drifts back into the source language.
    static let deviceSegment = 1_200

    /// A passage's paragraphs: runs of lines between blank lines, trimmed.
    static func paragraphs(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { out.append(current.joined(separator: "\n")); current = [] }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { out.append(current.joined(separator: "\n")) }
        return out
    }

    /// The passage in parts of at most `limit` characters, each translated
    /// by its own request and joined with a blank line: whole paragraphs
    /// packed together, a paragraph longer than the limit cut between
    /// sentences, a sentence longer than that between words.
    static func segments(_ text: String, limit: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for paragraph in paragraphs(text) {
            for piece in pieces(paragraph, limit: limit) {
                if current.isEmpty {
                    current = piece
                } else if current.count + 2 + piece.count <= limit {
                    current += "\n\n" + piece
                } else {
                    out.append(current)
                    current = piece
                }
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// One paragraph in parts that fit `limit`.
    private static func pieces(_ paragraph: String, limit: Int) -> [String] {
        guard paragraph.count > limit else { return [paragraph] }
        var sentences: [String] = []
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            sentences.append(String(paragraph[enclosing]))
        }
        if sentences.isEmpty { sentences = [paragraph] }
        var out: [String] = []
        var current = ""
        func close() {
            let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(t) }
            current = ""
        }
        for sentence in sentences {
            if current.count + sentence.count > limit { close() }
            var rest = Substring(sentence)
            // A sentence no part can hold: cut on a word.
            while rest.count > limit {
                let head = rest.prefix(limit)
                let cut = head.lastIndex(where: { $0.isWhitespace }) ?? head.endIndex
                let part = cut > rest.startIndex ? rest[..<cut] : head
                current = String(part)
                close()
                rest = rest[part.endIndex...]
            }
            current += rest
        }
        close()
        return out
    }

    /// A selection longer than this is cut before it is translated: the
    /// panel is for a paragraph or a page. It is also what one request to
    /// a large model carries.
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
