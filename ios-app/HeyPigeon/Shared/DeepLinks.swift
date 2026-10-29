// heypigeon:// links from the widgets, the Live Activity and the share
// extension, the Controls' targets, and the pending share the share
// extension leaves in the App Group — all land in AppModel here.

import Foundation
import UIKit

enum DeepLink: Equatable {
    case thread(id: String)
    case compose
    case folder(MailView)

    init?(url: URL) {
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
        }
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
