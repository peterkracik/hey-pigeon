// Snippets: short pieces of text the user writes once and drops into a
// message (an address, a polite no, the Friday status). They are a synced
// pref — one JSON string — so every device has them; the Mac's composer
// and command palette insert them, Settings › Compose edits them.

import Foundation

struct Snippet: Codable, Identifiable, Hashable, Sendable {
    var id = UUID().uuidString
    var name: String
    var body: String
}

enum SnippetStore {
    /// The pref's value. Sorted keys, so the same snippets always encode
    /// to the same string and a device that changed nothing syncs nothing.
    static func encode(_ snippets: [Snippet]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snippets) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a pref value holds; nothing for a string that is not snippets.
    static func decode(_ raw: String) -> [Snippet] {
        (try? JSONDecoder().decode([Snippet].self, from: Data(raw.utf8))) ?? []
    }
}
