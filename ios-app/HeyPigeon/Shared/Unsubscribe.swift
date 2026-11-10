// Unsubscribing from a mailing list through the header the sender put on
// the message for that purpose (`List-Unsubscribe`, RFC 2369), which the
// core keeps with the message. In order of preference: a one-click POST
// to the sender's https address when the sender says that is enough (RFC
// 8058) — nothing opens, the request goes from this device straight to
// the sender; else a message to the sender's unsubscribe address, sent
// like any other (with its Undo); else the sender's web page in the
// browser. Parsing is pure, for the tests.

import Foundation

enum Unsubscribe {
    enum Method: Equatable {
        /// POST `List-Unsubscribe=One-Click` to this address.
        case post(URL)
        /// Send the mail this `mailto:` link describes.
        case mail(URL)
        /// Open the sender's page.
        case open(URL)
    }

    /// What a thread offers: how, and who from (for the toast).
    struct Offer: Equatable {
        let sender: String
        let method: Method
    }

    /// The addresses in a `List-Unsubscribe` value: `<mailto:…>, <https://…>`.
    static func links(in header: String) -> [URL] {
        var out: [URL] = []
        var rest = Substring(header)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let raw = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            if let url = URL(string: raw) { out.append(url) }
            rest = rest[rest.index(after: close)...]
        }
        return out
    }

    static func method(header: String, oneClick: Bool) -> Method? {
        let all = links(in: header)
        let https = all.first { $0.scheme?.lowercased() == "https" }
        let mail = all.first { $0.scheme?.lowercased() == "mailto" }
        let web = https ?? all.first { $0.scheme?.lowercased() == "http" }
        if oneClick, let https { return .post(https) }
        if let mail { return .mail(mail) }
        if let web { return .open(web) }
        return nil
    }

    /// The newest message from someone else that carries the header.
    static func offer(in mail: [MessageItem]) -> Offer? {
        for m in mail.reversed() where !m.isMine {
            guard let header = m.listUnsubscribe, let method = method(header: header, oneClick: m.unsubscribeOneClick) else { continue }
            return Offer(sender: m.fromName.isEmpty ? m.fromAddress : m.fromName, method: method)
        }
        return nil
    }

    enum Failure: LocalizedError {
        case refused(Int)
        var errorDescription: String? {
            switch self {
            case .refused(let status): "The sender's server answered \(status)."
            }
        }
    }

    /// The one-click request (RFC 8058), in a session of its own that
    /// keeps no cookies or cache, with a short timeout.
    static func post(_ url: URL) async throws {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        request.httpShouldHandleCookies = false
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (_, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<400).contains(http.statusCode) {
            throw Failure.refused(http.statusCode)
        }
    }
}
