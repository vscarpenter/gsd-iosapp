import Foundation
import Security
import Synchronization
import GSDSync
import GSDWire

/// `TokenStore` over the Keychain (§8.3), now in the App-Group access group (`SharedTokenKeychain`)
/// so the Share Extension can read the session and push a shared task directly (§10.3).
///
/// Earlier builds kept the token in an app-private item (no access group). `load` migrates it on
/// first touch: read the shared item; if absent, read the legacy item, copy it into the group, and
/// delete the original. `save` prefers the group and falls back to the legacy item if the group
/// write is refused (sign-in keeps working; the extension then just takes the outbox path).
/// No mutable state → `Sendable`.
struct KeychainTokenStore: TokenStore {
    /// Migration runs at most once per process: if the shared group is unavailable on this
    /// platform, every later `load` just answers from the private item instead of re-trying.
    private static let migrationAttempted = Mutex(false)

    func load() -> String? {
        if let shared = SharedTokenKeychain.load() { return shared }
        guard let legacy = Legacy.load() else { return nil }
        let firstTime = Self.migrationAttempted.withLock { attempted in
            defer { attempted = true }
            return !attempted
        }
        if firstTime {
            // Clear the private item BEFORE writing the shared one: a query with no access group
            // matches every group the app belongs to, so a later unscoped delete would take the
            // shared item with it. If the group write is refused, put the private item back.
            Legacy.clear()
            if SharedTokenKeychain.save(legacy) != errSecSuccess { Legacy.save(legacy) }
        }
        return legacy
    }

    func save(_ token: String) {
        Legacy.clear()                                                   // first — see `load`
        if SharedTokenKeychain.save(token) != errSecSuccess { Legacy.save(token) }
    }

    func clear() {
        SharedTokenKeychain.clear()
        Legacy.clear()
    }

    /// The app-private item earlier builds wrote, kept only for migration and as the save fallback. Same
    /// service/account as the shared item; the two differ only in access group.
    private enum Legacy {
        // Computed, not `static let`: a `[String: Any]` global is not Sendable under Swift 6.
        private static var base: [String: Any] {
            [kSecClass as String: kSecClassGenericPassword,
             kSecAttrService as String: SharedTokenKeychain.service,
             kSecAttrAccount as String: SharedTokenKeychain.account]
        }

        static func load() -> String? {
            var query = base
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
            return token
        }

        static func save(_ token: String) {
            SecItemDelete(base as CFDictionary)
            var add = base
            add[kSecValueData as String] = Data(token.utf8)
            // ThisDeviceOnly: the session token must not migrate via encrypted backups or
            // device-to-device restore — a restored device should re-authenticate.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }

        static func clear() {
            SecItemDelete(base as CFDictionary)
        }
    }
}
