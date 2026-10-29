// A silent push arrived: sync that account, tell the user about threads
// that are new since the last look, keep the badge honest (unread inbox +
// reminders that came due). Text is composed here from the local database —
// the relay never had it.
//
// Banners are communication notifications (like Messages or Superhuman):
// the sender's name and an initials avatar lead, the app icon sits as a
// small badge on it, instead of "Hey Pigeon" over every mail. Needs the
// usernotifications.communication entitlement and INSendMessageIntent in
// NSUserActivityTypes (project.yml); without them iOS shows the plain form.

import Foundation
import Intents
import SwiftUI
import UIKit
import UserNotifications

enum NewMailNotifier {
    private static let prefix = "newmail."
    /// iOS gives a background fetch about 30 s; leave headroom for the
    /// completion handler.
    private static let budget: Duration = .seconds(25)

    @MainActor
    static func handle(email: String?, model: AppModel) async -> UIBackgroundFetchResult {
        let accountId = email.flatMap { e in model.accounts.first { $0.id == e || $0.email == e }?.id }
        let before = Set(unreadInbox(model, accountId: accountId).map(\.id))

        let engine = model.engine
        let changed: Bool
        do {
            changed = try await withTimeout(budget) {
                if let accountId {
                    try await engine.syncNow(accountId: accountId)
                } else {
                    try await engine.syncAll()
                }
            }
        } catch {
            await refreshBadge(model)
            return .failed
        }

        let fresh = unreadInbox(model, accountId: accountId).filter { !before.contains($0.id) }
        // In front, the list is live and a banner would be noise.
        if UIApplication.shared.applicationState != .active {
            for row in fresh {
                await post(row)
            }
        }
        model.reloadAccounts()
        model.reload()
        await refreshBadge(model)
        return changed || !fresh.isEmpty ? .newData : .noData
    }

    /// Badge = unread in the unified inbox + reminders that came due, across
    /// every account. Also called after every sync and reload, so it is
    /// right with the relay off too.
    @MainActor
    static func refreshBadge(_ model: AppModel) async {
        let unread = (try? model.engine.unreadCounts(accountId: nil))?["inbox"] ?? 0
        let due = AppModel.due(model.scheduledThreads(accountId: nil)).count
        try? await UNUserNotificationCenter.current().setBadgeCount(unread + due)
    }

    @MainActor
    private static func unreadInbox(_ model: AppModel, accountId: String?) -> [ThreadRow] {
        ((try? model.engine.threads(in: .inbox, accountId: accountId, before: nil, limit: 200)) ?? [])
            .filter { !$0.isRead }
    }

    private static func post(_ row: ThreadRow) async {
        let (name, address) = sender(of: row)
        let content = UNMutableNotificationContent()
        content.title = name
        content.subtitle = row.subject.isEmpty ? "(no subject)" : row.subject
        content.body = row.snippet
        content.sound = .default
        content.threadIdentifier = row.accountId
        content.userInfo = ["threadId": row.id, "accountId": row.accountId]

        // The intent carries the sender; iOS takes name and image from it.
        // A failed update falls back to the plain banner, same text.
        let image = avatar(name: name, address: address)
        let person = INPerson(
            personHandle: INPersonHandle(value: address, type: .emailAddress),
            nameComponents: nil,
            displayName: name,
            image: image,
            contactIdentifier: nil,
            customIdentifier: address
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: row.subject,
            speakableGroupName: nil,
            conversationIdentifier: row.id,
            serviceName: nil,
            sender: person,
            attachments: nil
        )
        intent.setImage(image, forParameterNamed: \.sender)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        try? await interaction.donate()
        let shown: UNNotificationContent = (try? content.updating(from: intent)) ?? content

        // Delivered now; the identifier dedupes a second push for the same thread.
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: prefix + row.id, content: shown, trigger: nil)
        )
    }

    /// Who the banner is from: "Ana, Me (4)" → "Ana"; the address when the
    /// summary has no name (or is only "Me").
    private static func sender(of row: ThreadRow) -> (name: String, address: String) {
        let address = row.lastFromAddress
        let first = row.fromSummary.components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let name = first.isEmpty || first == "Me" ? (address.isEmpty ? row.fromSummary : address) : first
        return (name, address.isEmpty ? name : address)
    }

    /// Initial on a tag-coloured disc, the colour fixed per address so the
    /// same person always looks the same.
    private static func avatar(name: String, address: String) -> INImage {
        let colors = AccountColor.allCases
        let seed = address.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let fill = UIColor(Theme.tagForeground(colors[seed % colors.count]))
        let letter = String(name.first(where: \.isLetter) ?? "?").uppercased()

        let side: CGFloat = 180
        let png = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { ctx in
            fill.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: side * 0.46, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        }
        return INImage(imageData: png)
    }

    private struct Timeout: Error {}

    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ work: @escaping @MainActor () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw Timeout()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }
}
