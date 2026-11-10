// Send later: a finished message that goes out at a time the user picked.
// Gmail's API has no scheduled send, and the app has no server, so the
// message waits on the device that scheduled it and is sent by the app
// itself once the time has come — while it runs, or the next time it is
// opened. It is kept as a Gmail draft meanwhile, so the text is safe in
// the account whatever happens to the device. The list is a file next to
// the store (attachments included; too large for the defaults).

import Foundation

/// One message waiting for its time.
struct ScheduledSend: Identifiable, Hashable {
    /// The draft's key: scheduling the same draft again replaces it.
    let id: String
    let draft: SendDraft
    let accountId: String
    let at: Date
}

/// The send-later menu: the same calendar maths as the reminders.
enum SendLaterPreset: String, CaseIterable, Identifiable {
    case inAnHour, laterToday, tomorrow, nextWeek

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inAnHour: "In an hour"
        case .laterToday: "Later today"
        case .tomorrow: "Tomorrow morning"
        case .nextWeek: "Monday morning"
        }
    }

    /// When this preset means from `now`; nil when it has passed
    /// ("Later today" after 18:00).
    func date(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .inAnHour: return now.addingTimeInterval(3600)
        case .laterToday: return ReminderPreset.laterToday.date(now: now, calendar: calendar)
        case .tomorrow: return ReminderPreset.tomorrow.date(now: now, calendar: calendar)
        case .nextWeek: return ReminderPreset.nextWeek.date(now: now, calendar: calendar)
        }
    }

    static func available(now: Date = Date()) -> [(preset: SendLaterPreset, date: Date)] {
        allCases.compactMap { p in p.date(now: now).map { (p, $0) } }
    }
}

enum ScheduledSendStore {
    private struct Item: Codable {
        var id: String
        var accountId: String
        var at: Date
        var to: [String]
        var cc: [String]
        var bcc: [String]
        var subject: String
        var bodyText: String
        var bodyHTML: String?
        var attachments: [Attachment]
        var replyToThreadId: String?
    }

    private struct Attachment: Codable {
        var filename: String
        var mimeType: String
        var size: Int
        var dataBase64: String
    }

    /// Next to the engine's store, in the app's Application Support.
    static var defaultURL: URL? {
        try? FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("HeyPigeon", isDirectory: true)
            .appendingPathComponent("scheduled-sends.json")
    }

    static func load(from url: URL? = defaultURL) -> [ScheduledSend] {
        guard let url, let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.map { item in
            var d = SendDraft()
            d.to = item.to
            d.cc = item.cc
            d.bcc = item.bcc
            d.subject = item.subject
            d.bodyText = item.bodyText
            d.bodyHTML = item.bodyHTML
            d.attachments = item.attachments.map {
                DraftAttachment(filename: $0.filename, mimeType: $0.mimeType, size: $0.size, dataBase64: $0.dataBase64)
            }
            d.replyToThreadId = item.replyToThreadId
            d.fromAccountId = item.accountId
            d.draftKey = item.id
            d.draftSaved = true
            return ScheduledSend(id: item.id, draft: d, accountId: item.accountId, at: item.at)
        }
    }

    static func save(_ sends: [ScheduledSend], to url: URL? = defaultURL) {
        guard let url else { return }
        let items = sends.map { s in
            Item(id: s.id, accountId: s.accountId, at: s.at, to: s.draft.to, cc: s.draft.cc, bcc: s.draft.bcc,
                 subject: s.draft.subject, bodyText: s.draft.bodyText, bodyHTML: s.draft.bodyHTML,
                 attachments: s.draft.attachments.map {
                     Attachment(filename: $0.filename, mimeType: $0.mimeType, size: $0.size, dataBase64: $0.dataBase64)
                 },
                 replyToThreadId: s.draft.replyToThreadId)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
