import Testing
@testable import GSDSync

struct AppleIdentityTests {
    @Test func relayAddressIsDetected() {
        #expect(AppleIdentity.isRelayEmail("abc123@privaterelay.appleid.com"))
    }
    @Test func relayDetectionIsCaseInsensitive() {
        #expect(AppleIdentity.isRelayEmail("ABC@PrivateRelay.AppleID.Com"))
    }
    @Test func realEmailsAreNotRelay() {
        #expect(!AppleIdentity.isRelayEmail("vscarpenter@gmail.com"))
        #expect(!AppleIdentity.isRelayEmail("me@vinny.io"))
    }
    @Test func lookalikeDomainIsNotRelay() {
        #expect(!AppleIdentity.isRelayEmail("me@privaterelay.appleid.com.evil.com"))
    }
    @Test func emptyOrMalformedIsNotRelay() {
        #expect(!AppleIdentity.isRelayEmail(""))
        #expect(!AppleIdentity.isRelayEmail("privaterelay.appleid.com"))
    }
}
