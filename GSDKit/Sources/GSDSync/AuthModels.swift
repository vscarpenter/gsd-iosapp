import Foundation

/// `GET /api/collections/users/auth-methods` (modern PocketBase ≥0.23 — read `oauth2.providers[]`;
/// the deprecated top-level `authProviders` mirror is ignored). Internal.
struct AuthMethods: Decodable, Equatable {
    var providers: [OAuthProvider]
    private enum CodingKeys: String, CodingKey { case oauth2 }
    private enum OAuth2Keys: String, CodingKey { case providers }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let o = try c.nestedContainer(keyedBy: OAuth2Keys.self, forKey: .oauth2)
        providers = try o.decode([OAuthProvider].self, forKey: .providers)
    }
    init(providers: [OAuthProvider]) { self.providers = providers }
}

/// One provider entry. The `state`/`codeVerifier` are per-attempt PKCE values that MUST be threaded
/// back (verifier) and validated (state). Internal.
struct OAuthProvider: Decodable, Equatable {
    var name: String
    var displayName: String
    var state: String
    var authURL: String
    var codeVerifier: String
    var codeChallenge: String
    var codeChallengeMethod: String
}

/// `POST .../auth-with-oauth2` and `.../auth-refresh` result. `public` — the App reads the account.
public struct AuthResult: Decodable, Equatable, Sendable {
    public var token: String
    public var record: AuthRecord
}

/// The authenticated user (extra PB fields ignored). `public`.
public struct AuthRecord: Decodable, Equatable, Sendable {
    public var id: String
    public var email: String
}
