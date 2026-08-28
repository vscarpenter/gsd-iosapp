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

/// The relay check alone under-warned. A user who shares their real Apple address still
/// lands on a different PocketBase account from the Google one they use on the web, and
/// got no hint at all — sync just looked broken.
struct AppleAccountNoteTests {
    @Test func relayEmailWarnsThatTheAccountIsSeparate() {
        let note = AppleIdentity.accountNote(provider: "apple", email: "x@privaterelay.appleid.com")
        #expect(note == .relaySeparateAccount)
    }
    @Test func realAppleEmailStillWarns() {
        let note = AppleIdentity.accountNote(provider: "apple", email: "me@vinny.io")
        #expect(note == .appleMayDiffer)
    }
    @Test func appleWithNoEmailWarns() {
        #expect(AppleIdentity.accountNote(provider: "apple", email: nil) == .appleMayDiffer)
    }
    @Test func googleAndGithubGetNoNote() {
        #expect(AppleIdentity.accountNote(provider: "google", email: "me@vinny.io") == nil)
        #expect(AppleIdentity.accountNote(provider: "github", email: "me@vinny.io") == nil)
    }
    @Test func providerMatchIsCaseInsensitive() {
        #expect(AppleIdentity.accountNote(provider: "Apple", email: "me@vinny.io") == .appleMayDiffer)
    }
    @Test func anUnknownProviderGetsNoNote() {
        #expect(AppleIdentity.accountNote(provider: "", email: "me@vinny.io") == nil)
    }
}
