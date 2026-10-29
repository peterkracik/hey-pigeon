// What the share extension hands the app: text, links and files, written
// into the App Group and turned into a prefilled composer the next time the
// app is in front (or at once, when the extension manages to open it).
// The extension never sends; nothing leaves the device until Send.

import Foundation

struct PendingShare: Codable, Equatable {
    static let file = "pending-share.json"
    static let filesDirectory = "pending-share-files"
    /// The composer's own cap (ComposeView.maxAttachBytes).
    static let maxFileBytes = 18 * 1024 * 1024

    struct File: Codable, Equatable {
        let filename: String
        let mimeType: String
        /// Name inside `filesDirectory`.
        let storedName: String
        let size: Int
    }

    var subject: String = ""
    var text: String = ""
    var links: [URL] = []
    var files: [File] = []
    let createdAt: Date

    init(createdAt: Date = Date()) { self.createdAt = createdAt }

    var isEmpty: Bool { text.isEmpty && links.isEmpty && files.isEmpty && subject.isEmpty }

    /// The body: the text, then the links on their own lines.
    var bodyText: String {
        var parts: [String] = []
        if !text.isEmpty { parts.append(text) }
        if !links.isEmpty { parts.append(links.map(\.absoluteString).joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    static var filesURL: URL? {
        AppGroup.container?.appendingPathComponent(filesDirectory, isDirectory: true)
    }

    static func load() -> PendingShare? { AppGroup.read(PendingShare.self, from: file) }

    func save() -> Bool { AppGroup.write(self, to: PendingShare.file) }

    /// Forget the pending share and its files.
    static func clear() {
        AppGroup.remove(file)
        if let dir = filesURL { try? FileManager.default.removeItem(at: dir) }
    }
}
