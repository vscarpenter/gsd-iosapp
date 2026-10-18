import Foundation
import Security
import GSDModel

/// The PocketBase session token, in a keychain item both the app and its extensions can read.
///
/// The access group is the App Group itself: Apple documents that an app group name can be used
/// as a keychain access group with no `keychain-access-groups` entitlement and no team-ID prefix
/// ("Sharing access to keychain items among a collection of apps"). On macOS / Catalyst that
/// sharing only applies to data-protection keychain items, hence `kSecUseDataProtectionKeychain`
/// on every query (a no-op on iOS, where all items are data-protection items).
///
/// `AfterFirstUnlockThisDeviceOnly`: the session must not migrate via encrypted backups or
/// device-to-device restore — a restored device should re-authenticate (unchanged from the
/// app-private item this replaces). Foundation + Security only; no I/O beyond the keychain.
public enum SharedTokenKeychain {
    public static let service = "dev.vinny.gsd.auth"
    public static let account = "pocketbase-token"
    public static let accessGroup = AppGroup.id

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: accessGroup,
         kSecUseDataProtectionKeychain as String: true]
    }

    public static func load() -> String? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        return token
    }

    /// Replace-then-add. Returns the `SecItemAdd` status so the app can fall back to its private
    /// item if the shared group is somehow unavailable (it logs; the extension then simply skips).
    @discardableResult
    public static func save(_ token: String) -> OSStatus {
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(token.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil)
    }

    public static func clear() {
        SecItemDelete(base as CFDictionary)
    }
}
