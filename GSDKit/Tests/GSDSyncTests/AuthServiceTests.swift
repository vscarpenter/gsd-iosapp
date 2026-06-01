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
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
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
}
