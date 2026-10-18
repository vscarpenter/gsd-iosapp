import Foundation

/// Executes a `URLRequest` → (data, HTTP response). The seam that lets tests drive responses from
/// fixtures without a network. `package`: GSDSync's FeedbackClient and the sync tests use it.
package protocol RequestExecuting: Sendable {
    func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Live executor over `URLSession`. `package`.
package struct URLSessionExecutor: RequestExecuting {
    let session: URLSession
    package init(session: URLSession) { self.session = session }
    package func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw PocketBaseError.network("non-HTTP response") }
            return (data, http)
        } catch let e as PocketBaseError { throw e }
        catch { throw PocketBaseError.network(error.localizedDescription) }
    }
}

/// Minimal hand-built PocketBase REST client over `URLSession` (§7.0). The generic request/send
/// core lives here in `GSDWire` (GSDModel-only, GRDB-free) so the Share Extension can push a task
/// without the store; the auth endpoints are a `GSDSync` extension (`PocketBaseClient+Auth`) and
/// the task CRUD is in `PocketBaseTaskWrite` / `PocketBaseTaskList`. `public` — the App and the
/// extension construct it. Token header is the raw JWT.
public final class PocketBaseClient: Sendable {
    package let baseURL: String            // `package`: the GSDSync auth extension builds URLs from it
    private let executor: RequestExecuting

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.executor = URLSessionExecutor(session: session)
    }
    package init(baseURL: String, executor: RequestExecuting) {
        self.baseURL = baseURL
        self.executor = executor
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

    package func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
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

    /// Send a request expecting no body (204 DELETE). Maps non-2xx to `PocketBaseError` like `send`.
    package func sendNoContent(_ request: URLRequest) async throws {
        let (data, http) = try await executor.execute(request)
        guard (200..<300).contains(http.statusCode) else {
            if let env = try? JSONDecoder().decode(PBErrorEnvelope.self, from: data) {
                throw PocketBaseError.pocketBase(status: http.statusCode, message: env.message)
            }
            throw PocketBaseError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }
}
