// The quoted history at the end of a plain-text message, found two ways:
// `split` is the message view's fold (the desktop's EmailBody.svelte
// rules, "> " lines under an "On … wrote:" line), `ownText` the AI's
// reading of the same message, which also knows Outlook's header block
// and "Original Message" dividers. Pure Foundation, tested in ModelTests.

import Foundation

enum QuotedText {
    /// Splits a plain-text body into what was written and the trailing
    /// quote: a run of "> " lines (blank lines allowed), optionally after an
    /// "On … wrote:" line. Nil when there is no trailing quote or nothing
    /// before it, so non-quoted text is never hidden. Same rules as
    /// desktop-app/src/lib/EmailBody.svelte.
    nonisolated static func split(_ text: String) -> (main: String, quoted: String)? {
        let lines = text.components(separatedBy: "\n")
        var i = lines.count
        var hasQuote = false
        while i > 0 {
            let l = lines[i - 1]
            if l.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix(">") { hasQuote = true; i -= 1 }
            else if l.trimmingCharacters(in: .whitespaces).isEmpty { i -= 1 }
            else { break }
        }
        guard hasQuote, i < lines.count else { return nil }
        if i > 0, lines[i - 1].range(of: #"^On\s.+wrote:\s*$"#, options: .regularExpression) != nil { i -= 1 }
        let main = lines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !main.isEmpty else { return nil }
        return (main, lines[i...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// What the author wrote: the text up to the trailing history, however
    /// the sending client marked it — "> " lines, an "On … wrote:" line on
    /// its own, Outlook's "From: / Sent: / To:" block, or an "Original
    /// Message" divider. The whole text (trimmed) when no history is found
    /// or nothing precedes it. A thread's transcript is built from this,
    /// so a long thread does not repeat every earlier message once per
    /// reply.
    nonisolated static func ownText(_ text: String) -> String {
        if let split = split(text) { return split.main }
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where i > 0 {
            let t = line.trimmingCharacters(in: .whitespaces)
            let wrote = t.range(of: #"^On\s.+wrote:$"#, options: .regularExpression) != nil
            let divider = t.range(of: #"^-{2,}\s*Original Message\s*-{2,}$"#, options: [.regularExpression, .caseInsensitive]) != nil
            // A header block: "From:" with Sent / To / Date within the next lines.
            let header = t.hasPrefix("From:") && lines[(i + 1)...].prefix(4).contains { l in
                let s = l.trimmingCharacters(in: .whitespaces)
                return s.hasPrefix("Sent:") || s.hasPrefix("To:") || s.hasPrefix("Date:")
            }
            guard wrote || divider || header else { continue }
            let main = lines[..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !main.isEmpty { return main }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
