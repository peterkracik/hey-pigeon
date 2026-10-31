// Google consent through ASWebAuthenticationSession. The engine builds the
// URL (PKCE + state) and validates the callback; this file only owns the
// system sheet. The callback scheme is the reversed client id, declared in
// Info.plist (CFBundleURLSchemes ← GOOGLE_IOS_REVERSED_CLIENT_ID on the
// phone, GOOGLE_MAC_REVERSED_CLIENT_ID on the Mac).
//
// Threads: on the Mac the session's completion handler arrives on an XPC
// queue, not the main thread — a sheet that cannot start says so straight
// from Safari's launch agent — and the anchor can be asked for off the main
// thread too. Both are nonisolated here: the completion only resumes a
// continuation, the anchor is taken on the main actor before the sheet
// starts. The first Mac build crashed on exactly this: a main-actor closure
// called from that queue trips Swift 6's executor check.

import AuthenticationServices
import os
import Synchronization
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

@MainActor
final class OAuthCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    // Read from the nonisolated completion handler too.
    nonisolated private static let log = Logger(subsystem: "app.heypigeon", category: "oauth")

    /// The sheet on screen; held so it is not deallocated mid-consent.
    private var session: ASWebAuthenticationSession?
    /// The window the sheet attaches to, taken on the main actor as the
    /// sheet starts; `presentationAnchor(for:)` may be asked for it off it.
    nonisolated(unsafe) private var anchor: ASPresentationAnchor?

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
        anchor = Self.window()
        defer { session = nil }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
            let once = OneShot(continuation)
            let s = ASWebAuthenticationSession(url: start.url, callbackURLScheme: start.callbackScheme) { @Sendable url, error in
                if let url {
                    once.resume(.success(url))
                } else {
                    let failure = error ?? URLError(.cancelled)
                    Self.log.error("consent sheet ended without a callback: \(String(describing: failure), privacy: .public)")
                    once.resume(.failure(failure))
                }
            }
            // Fresh cookies each time: with two Google accounts the user must
            // be able to pick the other one.
            s.prefersEphemeralWebBrowserSession = true
            s.presentationContextProvider = self
            session = s
            // `start()` returning false means the sheet did not open. On the
            // phone the completion handler is then never called; the Mac can
            // call it as well, which is what `OneShot` is for.
            if !s.start() {
                Self.log.error("consent sheet did not start")
                once.resume(.failure(CouldNotStart()))
            }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Set in `authorize` before the sheet starts. The fallback is for a
        // call that never happens in practice (a window is main-actor work,
        // and this keeps the property unwrap-free).
        anchor ?? MainActor.assumeIsolated { ASPresentationAnchor() }
    }

    /// The key window, else any visible one: what the sheet attaches to.
    private static func window() -> ASPresentationAnchor {
        #if canImport(UIKit)
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        return windows.first { $0.isKeyWindow } ?? windows.first ?? ASPresentationAnchor()
        #elseif canImport(AppKit)
        return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
        #endif
    }
}

/// Resumes a continuation at most once, from any thread.
private final class OneShot<T: Sendable>: Sendable {
    private let slot: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        slot = Mutex(continuation)
    }

    func resume(_ result: Result<T, any Error>) {
        let taken = slot.withLock { value -> CheckedContinuation<T, any Error>? in
            defer { value = nil }
            return value
        }
        taken?.resume(with: result)
    }
}
