import GSDSync

/// A `TokenStore` with no session, for harness launches (`HarnessLaunch.isIsolated`). The harness
/// must never sync, and a dev-signed Catalyst build would otherwise read the installed app's real
/// session from the shared keychain (`SharedTokenKeychain`). A save is dropped, loudly: a sign-in
/// completed during a harness run is a mistake in the run, not something to carry into the next
/// real launch.
struct SignedOutTokenStore: TokenStore {
    func load() -> String? { nil }
    func save(_ token: String) {
        assertionFailure("a sign-in completed during a harness launch; the token was dropped")
    }
    func clear() {}
}
