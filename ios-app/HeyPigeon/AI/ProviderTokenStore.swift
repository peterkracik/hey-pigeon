// Sign-in tokens for third-party model providers (the Anthropic or Google
// package, once it is linked), in the Keychain under the app's own service
// — the WWDC26 recommendation: a token the user pastes or signs in for,
// never an API-key string in the binary, and never a value the app reads
// back onto the screen. The Rust core keeps the OpenAI key in the same
// Keychain through its own secret store; this is only for providers the
// Swift model layer runs.

import Foundation
import Security

enum ProviderTokenStore {
    private static let service = "app.heypigeon.ai-provider"

    static func token(for account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Store (or replace) a token. Empty removes it.
    @discardableResult
    static func set(_ token: String?, for account: String) -> Bool {
        remove(account)
        guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else { return true }
        let attributes: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData: Data(token.utf8),
        ]
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ account: String) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
