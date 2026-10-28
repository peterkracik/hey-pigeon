// Renders the AI summaries' markdown subset — "- " bullets and **bold** —
// the way SummaryText.svelte does on the desktop (see summaryFormat.ts).
// The summary prompts in crates/ffi/src/settings.rs ask for exactly this
// subset; nothing else is interpreted, so model output never becomes markup.

import SwiftUI

enum SummaryMarkup {
    struct Line: Equatable {
        /// True when the line started with a bullet marker ("- ", "* ", "• ", "1. ").
        var bullet: Bool
        var text: AttributedString
    }

    /// Split a summary into lines; blank lines are dropped.
    static func parse(_ raw: String) -> [Line] {
        raw.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let (bullet, body) = stripBullet(line)
                return Line(bullet: bullet, text: inline(body))
            }
    }

    private static func stripBullet(_ line: String) -> (Bool, String) {
        for marker in ["- ", "* ", "• "] where line.hasPrefix(marker) {
            return (true, String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
        }
        // Numbered markers the model may use anyway: "1. " / "2) ".
        var idx = line.startIndex
        while idx < line.endIndex, line[idx].isNumber { idx = line.index(after: idx) }
        if idx > line.startIndex, idx < line.endIndex, line[idx] == "." || line[idx] == ")" {
            let after = line.index(after: idx)
            if after < line.endIndex, line[after] == " " {
                return (true, String(line[after...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return (false, line)
    }

    /// Bold spans between ** markers; an unmatched ** stays literal text.
    static func inline(_ text: String) -> AttributedString {
        var out = AttributedString()
        var rest = Substring(text)
        while let open = rest.range(of: "**") {
            let afterOpen = rest[open.upperBound...]
            guard let close = afterOpen.range(of: "**") else { break }
            out += AttributedString(String(rest[..<open.lowerBound]))
            var bold = AttributedString(String(afterOpen[..<close.lowerBound]))
            bold.inlinePresentationIntent = .stronglyEmphasized
            out += bold
            rest = afterOpen[close.upperBound...]
        }
        out += AttributedString(String(rest))
        return out
    }
}

/// A summary as a bullet list with bold facts. Inherits font and colour
/// from the caller like a plain `Text` would.
struct SummaryTextView: View {
    let text: String

    var body: some View {
        let lines = SummaryMarkup.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.bullet {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(Theme.textTertiary)
                        Text(line.text)
                    }
                } else {
                    Text(line.text)
                }
            }
        }
    }
}
