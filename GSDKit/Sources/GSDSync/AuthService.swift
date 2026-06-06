import Foundation

/// Stateful-PKCE auth orchestration over the seams (§8). Stateless across calls — per-attempt
/// `{state, codeVerifier}` are LOCAL to `signIn`, never cached. `public`. PROBE-VERIFIED (17/17).
public struct AuthService: Sendable {
    private let client: PocketBaseClient
    private let presenter: WebAuthPresenting
    private let tokenStore: TokenStore
    private let config: AuthConfig
    private let refreshSkew: TimeInterval
    private let now: @Sendable () -> Date

    public init(client: PocketBaseClient, presenter: WebAuthPresenting, tokenStore: TokenStore,
                config: AuthConfig, refreshSkew: TimeInterval = 60,
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

    /// Native Sign in with Apple (design §2). The system sheet already performed the OAuth interaction;
    /// we only exchange the returned `authorizationCode` at PocketBase's `auth-with-oauth2`. No
    /// `auth-methods` fetch, no `state`, no web presenter. `codeVerifier`/`redirectURL` default empty —
    /// the native handshake has no PKCE verifier and no web redirect (distinct from the web flow's
    /// `AuthConfig.redirectURI`); confirm exact values at the live gate (§8).
    public func signInWithApple(authorizationCode: String,
                                codeVerifier: String = "",
                                redirectURL: String = "") async throws -> AuthResult {
        guard !authorizationCode.isEmpty else { throw AuthError.missingCode }
        let result = try await client.authWithOAuth2(
            provider: "apple", code: authorizationCode, codeVerifier: codeVerifier, redirectURL: redirectURL)
        tokenStore.save(result.token)
        return result
    }

    public func signOut() { tokenStore.clear() }

    /// A usable token, refreshing proactively near expiry; nil if signed out. Throws if refresh fails
    /// (caller prompts re-auth).
    public func validToken() async throws -> String? {
        guard let token = tokenStore.load() else { return nil }
        guard JWT.expiresWithin(refreshSkew, of: token, now: now()) else { return token }
        return try await refresh().token
    }

    /// Extend a still-valid JWT (no refresh-token). On failure, clear + signal re-auth.
    @discardableResult
    public func refresh() async throws -> AuthResult {
        guard let token = tokenStore.load() else { throw AuthError.notSignedIn }
        do {
            let result = try await client.authRefresh(token: token)
            tokenStore.save(result.token)
            return result
        } catch {
            tokenStore.clear()
            throw error
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
