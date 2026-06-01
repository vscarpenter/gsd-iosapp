import Foundation

/// Stateful-PKCE auth orchestration over the seams (§8). Stateless across calls — per-attempt
/// `{state, codeVerifier}` are LOCAL to `signIn`, never cached. `public`. PROBE-VERIFIED (17/17).
/// (Refresh/validToken land in B2.)
public struct AuthService: Sendable {
    private let client: PocketBaseClient
    private let presenter: WebAuthPresenting
    private let tokenStore: TokenStore
    private let config: AuthConfig

    public init(client: PocketBaseClient, presenter: WebAuthPresenting, tokenStore: TokenStore, config: AuthConfig) {
        self.client = client; self.presenter = presenter; self.tokenStore = tokenStore; self.config = config
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
