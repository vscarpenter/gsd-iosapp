import Testing
import GSDModel
import GSDStore

struct StoreLocationTests {
    @Test func appGroupIDStaysInSyncWithSharedConstant() {
        #expect(StoreLocation.appGroupID == AppGroup.id)
        #expect(StoreLocation.appGroupID == "group.dev.vinny.gsd")
    }
}
