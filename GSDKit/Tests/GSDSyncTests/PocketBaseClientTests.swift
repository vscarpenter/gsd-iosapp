import Testing
import Foundation
@testable import GSDSync

struct PocketBaseClientTests {
    final class FakeExecutor: RequestExecuting, @unchecked Sendable {
        var routes: [String: (Data, Int)] = [:]
        private(set) var lastRequest: URLRequest?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastRequest = request
            let path = request.url!.path
            let (data, status) = routes.first { path.hasSuffix($0.key) }?.value ?? (Data(), 404)
            let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, resp)
        }
    }
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func client(_ exec: FakeExecutor) -> PocketBaseClient {
        PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
    }

    @Test func authMethodsDecodesAndIsUnauthenticated() async throws {
        let exec = FakeExecutor(); exec.routes["auth-methods"] = (try fixture("auth_methods"), 200)
        let methods = try await client(exec).authMethods()
        #expect(methods.providers.contains { $0.name == "google" })
        #expect(exec.lastRequest?.httpMethod == "GET")
        #expect(exec.lastRequest?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func authWithOAuth2SendsPKCEBodyAndDecodes() async throws {
        let exec = FakeExecutor(); exec.routes["auth-with-oauth2"] = (try fixture("auth_with_oauth2"), 200)
        let result = try await client(exec).authWithOAuth2(
            provider: "google", code: "CODE", codeVerifier: "VERIFIER_G", redirectURL: "https://api.vinny.io/ios-oauth-redirect/")
        #expect(result.record.email == "v@example.com")
        let body = try #require(exec.lastRequest?.httpBody)
        let sent = try JSONDecoder().decode([String: String].self, from: body)
        #expect(sent["provider"] == "google")
        #expect(sent["code"] == "CODE")
        #expect(sent["codeVerifier"] == "VERIFIER_G")
        #expect(sent["redirectURL"] == "https://api.vinny.io/ios-oauth-redirect/")
    }

    @Test func errorStatusMapsToPocketBaseError() async throws {
        let exec = FakeExecutor(); exec.routes["auth-with-oauth2"] = (try fixture("pb_error"), 400)
        await #expect(throws: PocketBaseError.pocketBase(status: 400, message: "Failed to authenticate.")) {
            _ = try await client(exec).authWithOAuth2(provider: "google", code: "x", codeVerifier: "v", redirectURL: "r")
        }
    }

    @Test func authRefreshSetsAuthorizationHeader() async throws {
        let exec = FakeExecutor(); exec.routes["auth-refresh"] = (try fixture("auth_with_oauth2"), 200)
        _ = try await client(exec).authRefresh(token: "TOK")
        #expect(exec.lastRequest?.value(forHTTPHeaderField: "Authorization") == "TOK")
    }
}
