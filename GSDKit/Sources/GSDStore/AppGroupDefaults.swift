import Foundation

/// Store-layer App-Group `UserDefaults` for small UI/config state that is NOT task data
/// (pinning + archive settings — design-spec scope call). Falls back to `.standard` if
/// the group is unavailable (e.g. a plain simulator run without the entitlement). The
/// suite is injectable so the store's pinning/settings logic is unit-testable.
public enum AppGroupDefaults {
    nonisolated(unsafe) public static let shared: UserDefaults =
        UserDefaults(suiteName: StoreLocation.appGroupID) ?? .standard

    public enum Key {
        public static let pinnedSmartViewIds = "pinnedSmartViewIds"
        public static let archiveAutoEnabled = "archiveAutoEnabled"
        public static let archiveAfterDays = "archiveAfterDays"
    }
}

/// Archive auto-sweep configuration (design-spec scope call): persisted in App-Group
/// UserDefaults, NOT a GRDB table. `afterDays` is constrained to the three offered values.
public struct ArchiveSettings: Equatable, Sendable {
    public var autoEnabled: Bool
    public var afterDays: Int        // 30 / 60 / 90
    public static let allowedDays = [30, 60, 90]
    public init(autoEnabled: Bool = false, afterDays: Int = 30) {
        self.autoEnabled = autoEnabled
        self.afterDays = ArchiveSettings.allowedDays.contains(afterDays) ? afterDays : 30
    }
}
