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

import AppIntents
import Foundation
import Intents
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import UserNotifications

enum NewMailNotifier {
    private static let prefix = "newmail."
    /// iOS gives a background fetch about 30 s; leave headroom for the
    /// completion handler.
    private static let budget: Duration = .seconds(25)

    /// What a push-driven fetch reports back: UIKit's own result on iOS;
    /// the Mac's delegate has no completion handler, so the same three
    /// outcomes as a plain enum.
    #if canImport(UIKit)
    typealias FetchResult = UIBackgroundFetchResult
    #else
    enum FetchResult { case newData, noData, failed }
    #endif

    @MainActor
    static func handle(email: String?, model: AppModel) async -> FetchResult {
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
        if !AppLifecycle.isActive {
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
    /// right with the relay off too. The reminders come from the model's
    /// last reload (every caller has just reloaded); only the unread count
    /// is read fresh.
    @MainActor
    static func refreshBadge(_ model: AppModel) async {
        let unread = (try? model.engine.unreadCounts(accountId: nil))?["inbox"] ?? 0
        let due = AppModel.due(model.scheduledAcrossAccounts).count
        try? await UNUserNotificationCenter.current().setBadgeCount(unread + due)
    }

    /// The unread inbox threads right now (one account or all): what a
    /// sync's "new since the last look" is measured against. The Mac's
    /// timer sync diffs it the same way (HeyPigeonMacApp).
    @MainActor
    static func unreadInbox(_ model: AppModel, accountId: String?) -> [ThreadRow] {
        ((try? model.engine.threads(in: .inbox, accountId: accountId, before: nil, limit: 200)) ?? [])
            .filter { !$0.isRead }
    }

    /// One banner for one new thread, composed here from the local store.
    static func post(_ row: ThreadRow) async {
        let (name, address) = sender(of: row)
        let content = UNMutableNotificationContent()
        content.title = name
        content.subtitle = row.subject.isEmpty ? "(no subject)" : row.subject
        content.body = row.snippet
        content.sound = .default
        content.threadIdentifier = row.accountId
        content.userInfo = ["threadId": row.id, "accountId": row.accountId]
        // iOS 27: Siri can act on "that notification" as the thread entity.
        content.appEntityIdentifiers = [MailThreadEntity.identifier(row.id)]

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
        #if os(iOS)
        // The Mac's Intents framework has no per-parameter image; the person's
        // own image above is what its banner shows.
        intent.setImage(image, forParameterNamed: \.sender)
        #endif
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
    static func sender(of row: ThreadRow) -> (name: String, address: String) {
        let address = row.lastFromAddress
        let name = row.leadSenderName ?? (address.isEmpty ? row.fromSummary : address)
        return (name, address.isEmpty ? name : address)
    }

    /// Initial on a tag-coloured disc, the colour fixed per address so the
    /// same person always looks the same.
    private static func avatar(name: String, address: String) -> INImage {
        let colors = AccountColor.allCases
        let seed = address.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let fill = PlatformColor(Theme.tagForeground(colors[seed % colors.count]))
        let letter = String(name.first(where: \.isLetter) ?? "?").uppercased()

        let side: CGFloat = 180
        let attrs: [NSAttributedString.Key: Any] = [
            .font: PlatformFont.systemFont(ofSize: side * 0.46, weight: .bold),
            .foregroundColor: PlatformColor.white,
        ]
        #if canImport(UIKit)
        let png = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).pngData { ctx in
            fill.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: side, height: side))
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
        }
        return INImage(imageData: png)
        #else
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
            let size = letter.size(withAttributes: attrs)
            letter.draw(at: CGPoint(x: (side - size.width) / 2, y: (side - size.height) / 2), withAttributes: attrs)
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            return INImage(imageData: Data())
        }
        return INImage(imageData: png)
        #endif
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
