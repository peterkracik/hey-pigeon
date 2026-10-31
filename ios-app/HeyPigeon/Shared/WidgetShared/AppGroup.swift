// The App Group the app shares with its widget and share extensions
// (docs/ios-intelligence.md, step 6). It holds a small JSON snapshot for
// the widgets, a pending share from the share sheet, and nothing else: the
// database and the Keychain stay in the app's own container.
//
// This folder (Shared/WidgetShared) is compiled into the app, the widget
// extension and the share extension. Foundation / SwiftUI / AppIntents /
// ActivityKit only — never the Rust core, never AppModel.

import Foundation

enum AppGroup {
    #if os(macOS)
    /// The Mac ships outside the App Store, signed with Developer ID and
    /// without a provisioning profile, and macOS only honors an App Group
    /// without one in the team-prefixed form (`TEAMID.group.app.heypigeon`).
    /// macos-app/project.yml writes the resolved name into each target's
    /// Info.plist next to the entitlement; an unsigned build (CI) has no
    /// team prefix and falls back to the plain name.
    static let identifier: String = {
        let value = Bundle.main.object(forInfoDictionaryKey: "HeyPigeonAppGroup") as? String ?? ""
        return value.isEmpty || value.hasPrefix("$(") ? "group.app.heypigeon" : value
    }()
    #else
    static let identifier = "group.app.heypigeon"
    #endif
    /// The widgets' kinds and the URL scheme the app opens on.
    static let urlScheme = "heypigeon"

    /// The shared container; nil when the entitlement is missing (a build
    /// without the capability), in which case the features degrade quietly.
    static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static func file(_ name: String) -> URL? {
        container?.appendingPathComponent(name, isDirectory: false)
    }

    static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.shared.decode(type, from: data)
    }

    @discardableResult
    static func write<T: Encodable>(_ value: T, to name: String) -> Bool {
        guard let url = file(name), let data = try? JSONEncoder.shared.encode(value) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    static func remove(_ name: String) {
        guard let url = file(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// `heypigeon://thread/<id>`, `heypigeon://compose`, `heypigeon://folder/<name>`,
    /// and the two the Mac widgets act through (their buttons cannot run in
    /// the app's process the way an iOS Live Activity intent can):
    /// `heypigeon://done/<id>` and `heypigeon://snooze/<id>/<hours>`.
    enum Link {
        static func thread(_ id: String) -> URL { URL(string: "\(urlScheme)://thread/\(encoded(id))")! }
        static let compose = URL(string: "\(urlScheme)://compose")!
        static func folder(_ raw: String) -> URL { URL(string: "\(urlScheme)://folder/\(raw)")! }
        static func done(_ id: String) -> URL { URL(string: "\(urlScheme)://done/\(encoded(id))")! }
        static func snooze(_ id: String, hours: Int = 1) -> URL { URL(string: "\(urlScheme)://snooze/\(encoded(id))/\(max(1, hours))")! }

        private static func encoded(_ id: String) -> String {
            id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        }
    }
}

/// Limits shared by the composer and the share extension.
enum MailLimits {
    /// Attachments per message, raw bytes. Gmail caps a message at 25 MB,
    /// and base64 grows attachments by a third.
    static let maxAttachmentBytes = 18 * 1024 * 1024
}

extension JSONEncoder {
    static let shared: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}

extension JSONDecoder {
    static let shared: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
