// Google consent through ASWebAuthenticationSession. The engine builds the
// URL (PKCE + state) and validates the callback; this file only owns the
// system sheet. The callback scheme is the reversed iOS client id, declared
// in Info.plist (CFBundleURLSchemes ← GOOGLE_IOS_REVERSED_CLIENT_ID).

import AuthenticationServices
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    /// The sheet on screen; held so it is not deallocated mid-consent.
    private var session: ASWebAuthenticationSession?

    /// The sheet could not be shown (no window to present over, or another
    /// session already up). Without this the continuation never resumed
    /// and "Add account" waited forever.
    struct CouldNotStart: LocalizedError {
        var errorDescription: String? { "The Google sign-in sheet couldn't open. Try again." }
    }

    /// Shows the consent sheet and resolves with the callback URL. A user
    /// cancel arrives as the session's own error (AppModel.addAccount
    /// treats it as no error at all).
    func authorize(_ start: OAuthStart) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { cont in
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
            // `start()` returning false means the completion handler is never
            // called: resume here instead.
            if !s.start() { cont.resume(throwing: CouldNotStart()) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        #if canImport(UIKit)
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        NSApp.keyWindow ?? ASPresentationAnchor()
        #endif
    }
}
