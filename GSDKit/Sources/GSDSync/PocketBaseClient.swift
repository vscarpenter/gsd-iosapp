import Foundation

/// Executes a `URLRequest` → (data, HTTP response). The seam that lets tests drive responses from
/// fixtures without a network. Internal.
protocol RequestExecuting: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live executor over `URLSession`. Internal.
struct URLSessionExecutor: RequestExecuting {
    let session: URLSession
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PocketBaseError.network("non-HTTP response") }
            return (data, http)
        } catch let e as PocketBaseError { throw e }
        catch { throw PocketBaseError.network(error.localizedDescription) }
    }
}

/// Minimal hand-built PocketBase REST client over `URLSession` (§7.0). Auth endpoints for 5b; the
/// generic `authedRequest` helper is consumed by 5c's CRUD. `public` — the App constructs it. Token
/// header is the raw JWT.
public final class PocketBaseClient: Sendable {
    private let baseURL: String
    private let executor: RequestExecuting

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.executor = URLSessionExecutor(session: session)
    }
    init(baseURL: String, executor: RequestExecuting) {
        self.baseURL = baseURL
        self.executor = executor
    }

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

    /// Authed request builder for 5c CRUD (raw token in Authorization). `public`.
    public func authedRequest(path: String, method: String, token: String, body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, http) = try await executor.execute(request)
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(PBErrorEnvelope.self, from: data) {
                throw PocketBaseError.pocketBase(status: http.statusCode, message: env.message)
            }
            throw PocketBaseError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw PocketBaseError.decoding(String(describing: error)) }
    }
}
