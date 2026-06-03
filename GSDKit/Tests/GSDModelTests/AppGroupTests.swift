import Testing
import GSDModel

struct AppGroupTests {
    @Test func idMatchesEntitlementString() {
        // Must match com.apple.security.application-groups in every target's entitlements.
        #expect(AppGroup.id == "group.dev.vinny.gsd")
    }
}
