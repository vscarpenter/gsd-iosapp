import GSDSync

/// A `TokenStore` with no session, for `--demo-seed` launches. The harness must never sync, and a
/// dev-signed Catalyst build would otherwise read the installed app's real session from the shared
/// keychain (`SharedTokenKeychain`). Saves are dropped too, so a stray sign-in in demo mode cannot
/// leave a token behind for the next real launch.
struct SignedOutTokenStore: TokenStore {
    func load() -> String? { nil }
    func save(_ token: String) {}
    func clear() {}
}
