import Foundation
import GSDWire

/// Stateful-PKCE auth orchestration over the seams (§8). Stateless across calls — per-attempt
/// `{state, codeVerifier}` are LOCAL to `signIn`, never cached. `public`. PROBE-VERIFIED (17/17).
public struct AuthService: Sendable {
    private let client: PocketBaseClient
    private let presenter: WebAuthPresenting
    private let tokenStore: TokenStore
    private let config: AuthConfig
    private let refreshSkew: TimeInterval
    private let now: @Sendable () -> Date

    /// `refreshSkew` defaults to 7 days: PocketBase auth tokens live ~14 days, so any sync in the
    /// back half of the lifetime extends the session. (A seconds-scale skew means an active user's
    /// token silently expires — refresh would only fire if a sync landed inside that tiny window.)
    public init(client: PocketBaseClient, presenter: WebAuthPresenting, tokenStore: TokenStore,
                config: AuthConfig, refreshSkew: TimeInterval = 7 * 24 * 60 * 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.presenter = presenter; self.tokenStore = tokenStore
        self.config = config; self.refreshSkew = refreshSkew; self.now = now
    }

    /// ONE auth-methods fetch; hold `{state, codeVerifier}` locally; present; validate state; exchange; store.
    public func signIn(provider: String) async throws -> AuthResult {
        let methods = try await client.authMethods()
        guard let p = methods.providers.first(where: { $0.name == provider }) else {
            throw AuthError.providerNotFound(provider)
        }
        let authURL = try buildAuthURL(p.authURL, redirectURI: config.redirectURI)
        let callback = try await presenter.present(authURL: authURL, callbackURLScheme: config.callbackScheme)
        let (code, state) = parseCallback(callback)
        guard state == p.state else { throw AuthError.stateMismatch }
        guard let code else { throw AuthError.missingCode }
        let result = try await client.authWithOAuth2(
            provider: provider, code: code, codeVerifier: p.codeVerifier, redirectURL: config.redirectURI)
        tokenStore.save(result.token)
        return result
    }

    public func signOut() { tokenStore.clear() }

    /// The signed-in PocketBase user id from the STORED token (no validation, no refresh) —
    /// the App's account-switch guard records this as the last-known owner. nil when signed
    /// out or the token is unparseable.
    public func currentUserId() -> String? {
        tokenStore.load().flatMap { JWT.userId($0) }
    }

    /// A usable token, refreshing proactively near expiry; nil if signed out. A transient refresh
    /// failure (offline, 5xx) falls back to the stored token while it still has life left — the
    /// next sync retries the refresh. Throws only when no usable token remains (caller prompts re-auth).
    public func validToken() async throws -> String? {
        guard let token = tokenStore.load() else { return nil }
        guard JWT.expiresWithin(refreshSkew, of: token, now: now()) else { return token }
        do {
            return try await refresh().token
        } catch {
            if tokenStore.load() != nil, !JWT.expiresWithin(0, of: token, now: now()) { return token }
            throw error
        }
    }

    /// Preferred account deletion (B-08): `DELETE /api/gsd/account` erases tasks and the user in one
    /// server transaction. The route is absent on api.vinny.io today (404), so the 404 is thrown
    /// untouched with the token kept: `AccountDeleter` falls back to the client-side erase.
    public func deleteAccountViaRoute() async throws {
        try await deleteAuthed(path: "/api/gsd/account")
    }

    /// Fallback step: deletes the signed-in user's PocketBase account record (App Store 5.1.1(v)).
    /// The caller MUST have erased the user's tasks first: once the record is gone the token is
    /// invalid and tasks can no longer be removed.
    public func deleteAccount() async throws {
        guard let id = currentUserId() else { throw AuthError.notSignedIn }
        try await deleteAuthed(path: "/api/collections/users/records/\(id)")
    }

    /// On a confirmed delete, and on a 401/403 where the session is already dead, the Keychain token
    /// is cleared; any other failure leaves it so the user can retry.
    private func deleteAuthed(path: String) async throws {
        guard currentUserId() != nil, let token = try await validToken() else { throw AuthError.notSignedIn }
        do {
            try await client.sendNoContent(client.authedRequest(path: path, method: "DELETE", token: token))
        } catch {
            if Self.isAuthRejection(error) { tokenStore.clear() }
            throw error
        }
        tokenStore.clear()
    }

    /// Extend a still-valid JWT (no refresh-token). The Keychain is cleared ONLY when the server
    /// rejects the token itself (401/403) — a transient network/server failure must not sign the
    /// user out (offline-first: airplane mode during a refresh is routine, not a session loss).
    @discardableResult
    public func refresh() async throws -> AuthResult {
        guard let token = tokenStore.load() else { throw AuthError.notSignedIn }
        do {
            let result = try await client.authRefresh(token: token)
            tokenStore.save(result.token)
            return result
        } catch {
            if Self.isAuthRejection(error) { tokenStore.clear() }
            throw error
        }
    }

    private static func isAuthRejection(_ error: Error) -> Bool {
        switch error {
        case PocketBaseError.http(let status, _), PocketBaseError.pocketBase(let status, _):
            status == 401 || status == 403
        default:
            false
        }
    }

    // MARK: helpers (internal — exercised via signIn; PROBE-VERIFIED)
    func buildAuthURL(_ base: String, redirectURI: String) throws -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let enc = redirectURI.addingPercentEncoding(withAllowedCharacters: allowed) ?? redirectURI
        guard let url = URL(string: base + enc) else { throw AuthError.presentationFailed }
        return url
    }
    func parseCallback(_ url: URL) -> (code: String?, state: String?) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return (items.first { $0.name == "code" }?.value, items.first { $0.name == "state" }?.value)
    }
}
