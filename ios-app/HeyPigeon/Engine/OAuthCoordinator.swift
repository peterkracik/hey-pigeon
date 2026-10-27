// Google consent through ASWebAuthenticationSession. The engine builds the
// URL (PKCE + state) and validates the callback; this file only owns the
// system sheet. The callback scheme is the reversed iOS client id, declared
// in Info.plist (CFBundleURLSchemes ← GOOGLE_IOS_REVERSED_CLIENT_ID).

import AuthenticationServices
import UIKit

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    /// Shows the consent sheet and resolves with the callback URL.
    func authorize(_ start: OAuthStart) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            let s = ASWebAuthenticationSession(url: start.url, callbackURLScheme: start.callbackScheme) { url, error in
                if let url { cont.resume(returning: url) } else {
                    cont.resume(throwing: error ?? URLError(.cancelled))
                }
            }
            // Fresh cookies each time: with two Google accounts the user must
            // be able to pick the other one.
            s.prefersEphemeralWebBrowserSession = true
            s.presentationContextProvider = self
            session = s
            s.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
    }
}
