import Foundation

/// Stable per-device identity (§7.8): a persisted `deviceId` (UUID) generated once, plus a human
/// `deviceName`. Populates `device_id` on pushed records (echo filtering) and the sync-history /
/// device list. Stored in the App-Group container so extensions share identity. The defaults suite
/// + name source are injectable so the logic is deterministic in tests and the package stays
/// UIKit-free (the App passes `UIDevice.current.name` at the call site).
public struct DeviceIdentity: Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String

    /// Returns the existing identity, or generates + persists a new `deviceId` on first call.
    /// `deviceName` is refreshed from `nameProvider` each call (a device can be renamed).
    public static func current(
        defaults: UserDefaults = AppGroupDefaults.shared,
        newID: () -> String = { UUID().uuidString },
        nameProvider: () -> String = { "Unknown Device" }
    ) -> DeviceIdentity {
        let id: String
        if let existing = defaults.string(forKey: AppGroupDefaults.Key.deviceId) {
            id = existing
        } else {
            id = newID()
            defaults.set(id, forKey: AppGroupDefaults.Key.deviceId)
        }
        let name = nameProvider()
        defaults.set(name, forKey: AppGroupDefaults.Key.deviceName)
        return DeviceIdentity(deviceId: id, deviceName: name)
    }
}
