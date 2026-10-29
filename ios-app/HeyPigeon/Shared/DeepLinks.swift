// heypigeon:// links from the widgets, the Live Activity and the share
// extension, the Controls' targets, the pending share the share extension
// leaves in the App Group, and mailto: links — what iOS hands the default
// mail app (project.yml, the mail-client entitlement) when a mail link is
// tapped in Safari, Notes, a contact card or another app, and what a mail
// link inside a message body opens — all land in AppModel here.

import Foundation
import UIKit

enum DeepLink: Equatable {
    case thread(id: String)
    case compose
    case folder(MailView)
    /// A mailto: link, already a prefilled draft. Nothing is sent.
    case mailto(SendDraft)

    init?(url: URL) {
        if url.scheme?.lowercased() == "mailto" {
            self = .mailto(SendDraft(mailto: url))
            return
        }
        guard url.scheme == AppGroup.urlScheme else { return nil }
        let parts = [url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }
        switch parts.first {
        case "thread":
            guard parts.count > 1, let id = parts[1].removingPercentEncoding, !id.isEmpty else { return nil }
            self = .thread(id: id)
        case "compose":
            self = .compose
        case "folder":
            guard parts.count > 1, let f = MailFolder(rawValue: parts[1]) else { return nil }
            self = .folder(f.view)
        default:
            return nil
        }
    }

    init(_ target: ControlTarget) {
        switch target {
        case .inbox: self = .folder(.inbox)
        case .scheduled: self = .folder(.scheduled)
        case .needReply: self = .folder(.needReply)
        case .compose: self = .compose
        }
    }
}

extension AppModel {
    func handle(_ link: DeepLink) {
        switch link {
        case .thread(let id): openThread(id: id)
        case .compose:
            if !adoptPendingShare() { compose(SendDraft()) }
        case .folder(let view): show(view)
        case .mailto(let draft): compose(draft)
        }
    }

    /// Spotlight's "Search in Hey Pigeon" (and Siri handing a search over):
    /// the Search tab on these words, the filter buttons cleared.
    func openSearch(_ text: String) {
        showSidebar = false
        showSettings = false
        tab = .search
        searchFilters = SearchFilters()
        searchText = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The share extension left something: open the composer on it, once.
    @discardableResult
    func adoptPendingShare() -> Bool {
        guard let share = PendingShare.load() else { return false }
        defer { PendingShare.clear() }
        guard !share.isEmpty else { return false }
        compose(SendDraft(share))
        return true
    }
}

extension SendDraft {
    /// A share becomes a draft: the subject when the sharer gave one, the
    /// text and links as the body, the files as attachments (read from the
    /// App Group; anything missing or over the cap is skipped).
    init(_ share: PendingShare) {
        self.init()
        subject = share.subject
        bodyText = share.bodyText
        if let dir = PendingShare.filesURL {
            attachments = share.files.compactMap { f in
                guard f.size <= PendingShare.maxFileBytes,
                      let data = try? Data(contentsOf: dir.appendingPathComponent(f.storedName)) else { return nil }
                return DraftAttachment(filename: f.filename, mimeType: f.mimeType, size: data.count, dataBase64: data.base64EncodedString())
            }
        }
    }
}

extension SendDraft {
    /// RFC 6068: `mailto:a@x.com,b@y.com?subject=…&body=…&cc=…&bcc=…&to=…`.
    /// Addresses before the `?` and in `to=` are the recipients; the four
    /// header names are the only ones honoured (anything else a link could
    /// set — From, Reply-To, Content-Type — is dropped, as Mail does). Values
    /// are percent-decoded; a `+` stays a `+` (the RFC says so, and
    /// `thomas+news@…` is an address). Line breaks in the body arrive as
    /// `%0D%0A` and become plain newlines. A bare `mailto:` is an empty
    /// composer. The account is left to the composer's default.
    init(mailto url: URL) {
        self.init()
        var raw = url.absoluteString
        if let colon = raw.firstIndex(of: ":") { raw = String(raw[raw.index(after: colon)...]) }
        let pieces = raw.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        to = Self.mailtoAddresses(String(pieces.first ?? ""))
        guard pieces.count == 2 else { return }
        for pair in pieces[1].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = Self.mailtoDecode(String(kv[0])).lowercased()
            let value = kv.count == 2 ? Self.mailtoDecode(String(kv[1])) : ""
            switch key {
            case "to": to += Self.mailtoAddresses(value)
            case "cc": cc += Self.mailtoAddresses(value)
            case "bcc": bcc += Self.mailtoAddresses(value)
            case "subject": subject = value.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            case "body": bodyText = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            default: break
            }
        }
    }

    /// Comma-separated addresses, each percent-decoded and trimmed; the
    /// display-name form `Anna <anna@x.com>` is reduced to the address.
    private static func mailtoAddresses(_ s: String) -> [String] {
        mailtoDecode(s).split(separator: ",").compactMap { part in
            var a = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = a.lastIndex(of: "<"), let close = a[open...].firstIndex(of: ">") {
                a = String(a[a.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            }
            return a.isEmpty ? nil : a
        }
    }

    private static func mailtoDecode(_ s: String) -> String {
        s.removingPercentEncoding ?? s
    }
}
