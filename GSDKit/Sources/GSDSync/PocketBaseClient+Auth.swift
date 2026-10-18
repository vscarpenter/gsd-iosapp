import Foundation
import GSDWire

/// The PocketBase auth endpoints (§8), kept in `GSDSync` beside `AuthService`. The request/send
/// core is `GSDWire.PocketBaseClient`; only the auth flow needs these, so they stay out of the
/// GRDB-free wire target the Share Extension links.
extension PocketBaseClient {
    func authMethods() async throws -> AuthMethods {
        var req = URLRequest(url: URL(string: baseURL + "/api/collections/users/auth-methods")!)
        req.httpMethod = "GET"
        return try await send(req, as: AuthMethods.self)
    }

    func authWithOAuth2(provider: String, code: String, codeVerifier: String, redirectURL: String) async throws -> AuthResult {
        var req = URLRequest(url: URL(string: baseURL + "/api/collections/users/auth-with-oauth2")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(
            ["provider": provider, "code": code, "codeVerifier": codeVerifier, "redirectURL": redirectURL])
        return try await send(req, as: AuthResult.self)
    }

    func authRefresh(token: String) async throws -> AuthResult {
        var req = URLRequest(url: URL(string: baseURL + "/api/collections/users/auth-refresh")!)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "Authorization")
        return try await send(req, as: AuthResult.self)
    }
}
