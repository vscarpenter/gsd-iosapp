import Testing
import Foundation
@testable import GSDStore

struct DeviceIdentityTests {
    /// A fresh, isolated UserDefaults suite per test (never the shared App-Group one).
    private func freshDefaults() -> UserDefaults {
        let suite = "test.deviceidentity.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func generatesAndPersistsAStableDeviceId() {
        let defaults = freshDefaults()
        var generated = 0
        let make: () -> String = { generated += 1; return "uuid-\(generated)" }
        let first = DeviceIdentity.current(defaults: defaults, newID: make, nameProvider: { "iPhone" })
        let second = DeviceIdentity.current(defaults: defaults, newID: make, nameProvider: { "iPhone" })
        #expect(first.deviceId == "uuid-1")
        #expect(second.deviceId == "uuid-1")     // reused, not regenerated
        #expect(generated == 1)                   // newID called exactly once
    }

    @Test func capturesDeviceName() {
        let defaults = freshDefaults()
        let identity = DeviceIdentity.current(defaults: defaults, newID: { "x" }, nameProvider: { "Vinny's iPad" })
        #expect(identity.deviceName == "Vinny's iPad")
        #expect(defaults.string(forKey: AppGroupDefaults.Key.deviceName) == "Vinny's iPad")
    }

    @Test func refreshesNameOnRenameButKeepsId() {
        let defaults = freshDefaults()
        _ = DeviceIdentity.current(defaults: defaults, newID: { "x" }, nameProvider: { "Old Name" })
        let renamed = DeviceIdentity.current(defaults: defaults, newID: { "x" }, nameProvider: { "New Name" })
        #expect(renamed.deviceId == "x")          // id stable across rename
        #expect(renamed.deviceName == "New Name")
    }
}
