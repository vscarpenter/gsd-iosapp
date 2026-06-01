import Testing
import Foundation
@testable import GSDSync

struct AuthModelsTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test func decodesAuthMethodsModernShape() throws {
        let methods = try JSONDecoder().decode(AuthMethods.self, from: fixture("auth_methods"))
        #expect(methods.providers.count == 2)
        let google = try #require(methods.providers.first { $0.name == "google" })
        #expect(google.displayName == "Google")
        #expect(google.state == "STATE_G")
        #expect(google.codeVerifier == "VERIFIER_G")
        #expect(google.codeChallengeMethod == "S256")
        #expect(google.authURL.hasSuffix("redirect_uri="))
        #expect(methods.providers[1].name == "github")
    }

    @Test func decodesAuthResult() throws {
        let json = Data(#"{"token":"jwt.token.here","record":{"id":"u1","email":"v@example.com","extra":"ignored"}}"#.utf8)
        let result = try JSONDecoder().decode(AuthResult.self, from: json)
        #expect(result.token == "jwt.token.here")
        #expect(result.record.email == "v@example.com")
    }
}
