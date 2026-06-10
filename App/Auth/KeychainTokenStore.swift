import Foundation
import Security
import GSDSync

/// `TokenStore` over the Keychain (§8.3). A PLAIN generic-password item — NO access group (the shared
/// group needs a team/app-ID-prefix entitlement + an extension, both Phase 6). No mutable state → `Sendable`.
struct KeychainTokenStore: TokenStore {
    private let service = "dev.vinny.gsd.auth"
    private let account = "pocketbase-token"

    func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    func save(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        // ThisDeviceOnly: the session token must not migrate via encrypted backups or
        // device-to-device restore — a restored device should re-authenticate.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    func clear() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}
