import Testing
import Foundation
@testable import GSDSync

struct AuthServiceTests {
    final class FakePresenter: WebAuthPresenting, @unchecked Sendable {
        var result: Result<URL, Error>
        private(set) var presentedURL: URL?
        init(_ result: Result<URL, Error>) { self.result = result }
        func present(authURL: URL, callbackURLScheme: String) async throws -> URL {
            presentedURL = authURL
            return try result.get()
        }
    }
    final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
        private(set) var token: String?
        init(_ t: String? = nil) { token = t }
        func load() -> String? { token }
        func save(_ t: String) { token = t }
        func clear() { token = nil }
    }
    final class FakeExecutor: RequestExecuting, @unchecked Sendable {
        var routes: [String: (Data, Int)] = [:]
        private(set) var lastBody: Data?
        private(set) var lastRequest: URLRequest?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            if request.url!.path.hasSuffix("auth-with-oauth2") { lastBody = request.httpBody }
            let (data, status) = routes.first { request.url!.path.hasSuffix($0.key) }?.value ?? (Data(), 404)
            return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    private func makeService(presenter: WebAuthPresenting, store: TokenStore, exec: FakeExecutor) throws -> AuthService {
        exec.routes["auth-methods"] = (try fixture("auth_methods"), 200)
        exec.routes["auth-with-oauth2"] = (try fixture("auth_with_oauth2"), 200)
        return AuthService(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                           presenter: presenter, tokenStore: store, config: .live)
    }

    @Test func signInHappyPathThreadsVerifierAndStoresToken() async throws {
        let presenter = FakePresenter(.success(URL(string: "gsd://oauth-callback?code=AUTH_CODE&state=STATE_G")!))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        let result = try await service.signIn(provider: "google")
        #expect(result.record.email == "v@example.com")
        #expect(store.token == "header.payload.signature")
        let sent = try JSONDecoder().decode([String: String].self, from: #require(exec.lastBody))
        #expect(sent["codeVerifier"] == "VERIFIER_G")
        #expect(sent["code"] == "AUTH_CODE")
        #expect(presenter.presentedURL?.absoluteString.contains("redirect_uri=https%3A%2F%2Fapi.vinny.io%2Fios-oauth-redirect%2F") == true)
    }

    @Test func stateMismatchIsRejected() async throws {
        let presenter = FakePresenter(.success(URL(string: "gsd://oauth-callback?code=AUTH_CODE&state=WRONG")!))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        await #expect(throws: AuthError.stateMismatch) { _ = try await service.signIn(provider: "google") }
        #expect(store.token == nil)
    }

    @Test func userCancelPropagatesAndStoresNothing() async throws {
        let presenter = FakePresenter(.failure(AuthError.cancelled))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        await #expect(throws: AuthError.cancelled) { _ = try await service.signIn(provider: "google") }
        #expect(store.token == nil)
    }

    @Test func unknownProviderThrows() async throws {
        let presenter = FakePresenter(.success(URL(string: "gsd://oauth-callback?code=x&state=y")!))
        let store = InMemoryTokenStore(); let exec = FakeExecutor()
        let service = try makeService(presenter: presenter, store: store, exec: exec)
        await #expect(throws: AuthError.providerNotFound("apple")) { _ = try await service.signIn(provider: "apple") }
    }

    private func makeJWT(id: String? = nil, exp: Int) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let h = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        var claims = "\"exp\":\(exp)"
        if let id { claims = "\"id\":\"\(id)\",\(claims)" }
        return "\(h).\(b64url(Data("{\(claims)}".utf8))).sig"
    }
    private func refreshService(store: TokenStore, exec: FakeExecutor, now: Date) -> AuthService {
        AuthService(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                    presenter: FakePresenter(.failure(AuthError.cancelled)),
                    tokenStore: store, config: .live, now: { now })
    }

    @Test func validTokenReturnsFreshTokenWithoutRefreshing() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let fresh = makeJWT(exp: 1_893_456_000)
        let store = InMemoryTokenStore(fresh); let exec = FakeExecutor()
        let token = try await refreshService(store: store, exec: exec, now: now).validToken()
        #expect(token == fresh)
    }

    @Test func validTokenRefreshesWhenNearExpiry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(exp: 1_000_000_030)); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("auth_with_oauth2"), 200)
        let token = try await refreshService(store: store, exec: exec, now: now).validToken()
        #expect(token == "header.payload.signature")
        #expect(store.token == "header.payload.signature")
    }

    @Test func validTokenNilWhenSignedOut() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let token = try await refreshService(store: InMemoryTokenStore(), exec: FakeExecutor(), now: now).validToken()
        #expect(token == nil)
    }

    @Test func refreshAuthRejectionClearsTokenAndThrows() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(exp: 1_000_000_030)); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("pb_error"), 401)
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { _ = try await service.refresh() }
        #expect(store.token == nil)
    }

    @Test func refreshTransientFailureKeepsToken() async throws {   // offline ≠ signed out
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let current = makeJWT(exp: 1_000_000_030)
        let store = InMemoryTokenStore(current); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("pb_error"), 500)
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { _ = try await service.refresh() }
        #expect(store.token == current)
    }

    @Test func validTokenRefreshesDaysBeforeExpiry() async throws {   // PB tokens live ~14d; the skew must be days
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(exp: 1_000_000_000 + 3 * 86_400)); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("auth_with_oauth2"), 200)
        let token = try await refreshService(store: store, exec: exec, now: now).validToken()
        #expect(token == "header.payload.signature")
        #expect(store.token == "header.payload.signature")
    }

    @Test func validTokenFallsBackToStillValidTokenOnTransientRefreshFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let current = makeJWT(exp: 1_000_000_030)                      // near expiry, still valid
        let store = InMemoryTokenStore(current); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("pb_error"), 500)   // hiccup, not a rejection
        let token = try await refreshService(store: store, exec: exec, now: now).validToken()
        #expect(token == current)          // sync proceeds on the old token
        #expect(store.token == current)    // and the user is NOT signed out
    }

    @Test func validTokenThrowsForExpiredTokenWhenRefreshUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(exp: 999_999_990)); let exec = FakeExecutor()
        exec.routes["auth-refresh"] = (try fixture("pb_error"), 500)
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { _ = try await service.validToken() }
        #expect(store.token != nil)        // kept so health can report "session expired — sign in again"
    }

    @Test func signOutClearsToken() {
        let store = InMemoryTokenStore("tok")
        refreshService(store: store, exec: FakeExecutor(), now: Date(timeIntervalSince1970: 0)).signOut()
        #expect(store.token == nil)
    }

    @Test func currentUserIdReadsTheStoredTokenWithoutValidation() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJpZCI6InUxIiwiZXhwIjo5OTk5OTk5OTk5fQ.x"   // id u1
        let service = refreshService(store: InMemoryTokenStore(jwt), exec: FakeExecutor(),
                                     now: Date(timeIntervalSince1970: 0))
        #expect(service.currentUserId() == "u1")
    }
    @Test func currentUserIdNilWhenSignedOut() {
        let service = refreshService(store: InMemoryTokenStore(), exec: FakeExecutor(),
                                     now: Date(timeIntervalSince1970: 0))
        #expect(service.currentUserId() == nil)
    }

    @Test func deleteAccountBuildsAuthedDeleteForTheUserRecord() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let token = makeJWT(id: "u1", exp: 1_893_456_000)
        let store = InMemoryTokenStore(token); let exec = FakeExecutor()
        exec.routes["records/u1"] = (Data(), 204)
        try await refreshService(store: store, exec: exec, now: now).deleteAccount()
        #expect(exec.lastRequest?.httpMethod == "DELETE")
        #expect(exec.lastRequest?.url?.path.hasSuffix("/api/collections/users/records/u1") == true)
        #expect(exec.lastRequest?.value(forHTTPHeaderField: "Authorization") == token)
        #expect(store.token == nil)   // success ends the session
    }

    @Test func deleteAccountAuthRejectionClearsTokenAndThrows() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let store = InMemoryTokenStore(makeJWT(id: "u1", exp: 1_893_456_000)); let exec = FakeExecutor()
        exec.routes["records/u1"] = (try fixture("pb_error"), 403)
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { try await service.deleteAccount() }
        #expect(store.token == nil)   // dead session → cleared
    }

    @Test func deleteAccountTransientFailureKeepsTokenForRetry() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let kept = makeJWT(id: "u1", exp: 1_893_456_000)
        let store = InMemoryTokenStore(kept); let exec = FakeExecutor()
        exec.routes["records/u1"] = (try fixture("pb_error"), 500)   // hiccup, not a rejection
        let service = refreshService(store: store, exec: exec, now: now)
        await #expect(throws: PocketBaseError.self) { try await service.deleteAccount() }
        #expect(store.token == kept)  // retryable; NOT signed out
    }

    @Test func deleteAccountThrowsNotSignedInWhenNoToken() async throws {
        let service = refreshService(store: InMemoryTokenStore(), exec: FakeExecutor(),
                                     now: Date(timeIntervalSince1970: 1_000_000_000))
        await #expect(throws: AuthError.notSignedIn) { try await service.deleteAccount() }
    }
}
