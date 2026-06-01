import Testing
import Foundation
@testable import GSDSync

struct JWTTests {
    private func makeJWT(_ payloadJSON: String) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let header = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        return "\(header).\(b64url(Data(payloadJSON.utf8))).sig"
    }

    @Test func decodesExp() {
        let token = makeJWT(#"{"exp":1893456000,"id":"u1"}"#)
        #expect(JWT.expiry(token).map { Int($0.timeIntervalSince1970) } == 1893456000)
    }

    @Test func malformedTokenHasNoExpiry() {
        #expect(JWT.expiry("only.two") == nil)
        #expect(JWT.expiry("garbage") == nil)
    }

    @Test func expiresWithinSkew() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        let soon = makeJWT(#"{"exp":1000000030}"#)
        let far  = makeJWT(#"{"exp":1893456000}"#)
        #expect(JWT.expiresWithin(60, of: soon, now: now) == true)
        #expect(JWT.expiresWithin(60, of: far, now: now) == false)
        #expect(JWT.expiresWithin(60, of: "garbage", now: now) == true)
    }
}
