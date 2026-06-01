import Foundation

/// Injected config for the auth flow (not hardcoded). `public`.
public struct AuthConfig: Sendable {
    public var baseURL: String
    public var redirectURI: String
    public var callbackScheme: String
    public init(baseURL: String, redirectURI: String, callbackScheme: String) {
        self.baseURL = baseURL; self.redirectURI = redirectURI; self.callbackScheme = callbackScheme
    }
    /// The owner's live backend + the configured bounce redirect (set up + tested).
    public static let live = AuthConfig(
        baseURL: "https://api.vinny.io",
        redirectURI: "https://api.vinny.io/ios-oauth-redirect/",
        callbackScheme: "gsd")
}

/// Presents an OAuth web-auth session and returns the final callback URL. App impl =
/// `ASWebAuthenticationSession`; tests use a fake. (Mirrors the Phase-4 `ReminderScheduling` seam.) `public`.
public protocol WebAuthPresenting: Sendable {
    func present(authURL: URL, callbackURLScheme: String) async throws -> URL
}

/// Persists the auth token. App impl = Keychain; tests = in-memory. `public`.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

public enum AuthError: Error, Equatable, Sendable {
    case cancelled
    case presentationFailed
    case stateMismatch
    case missingCode
    case providerNotFound(String)
    case notSignedIn
}
