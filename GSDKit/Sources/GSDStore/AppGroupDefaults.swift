import Foundation
import GSDModel

/// Store-layer App-Group `UserDefaults` for small UI/config state that is NOT task data
/// (pinning + archive settings — design-spec scope call). Falls back to `.standard` if
/// the group is unavailable (e.g. a plain simulator run without the entitlement). The
/// suite is injectable so the store's pinning/settings logic is unit-testable.
public enum AppGroupDefaults {
    /// In a harness launch (`HarnessLaunch.isIsolated`) this is a suite that starts empty and
    /// never aliases the App Group's, so nothing the harness stores reaches the real app.
    nonisolated(unsafe) public static let shared: UserDefaults =
        HarnessLaunch.isIsolated
            ? HarnessLaunch.makeIsolatedDefaults()
            : (UserDefaults(suiteName: StoreLocation.appGroupID) ?? .standard)

    public enum Key {
        public static let pinnedSmartViewIds = "pinnedSmartViewIds"
        public static let archiveAutoEnabled = "archiveAutoEnabled"
        public static let archiveAfterDays = "archiveAfterDays"
        public static let notificationsEnabled = "notificationsEnabled"
        public static let notificationDefaultReminder = "notificationDefaultReminder"
        public static let notificationSoundEnabled = "notificationSoundEnabled"
        public static let notificationQuietHoursStart = "notificationQuietHoursStart"
        public static let notificationQuietHoursEnd = "notificationQuietHoursEnd"
        public static let notificationPermissionAsked = "notificationPermissionAsked"
        public static let deviceId = AppGroup.deviceIDKey   // shared with the extension
        public static let deviceName = "deviceName"
        public static let fetchShareTitles = "fetchShareTitles"
        public static let escalationWindowDays = "escalationWindowDays"
        /// The iPad and Mac matrix layout, a `MatrixLayout` raw value. Per device, never synced.
        public static let matrixLayout = "matrixLayout"
        /// The newest release this device has acknowledged in What's New. Per device, never synced (D-15).
        public static let whatsNewLastSeenVersion = "whatsNewLastSeenVersion"
        /// Weekly sweep (D-14): when this device last finished a sweep, and its reminder. Per device,
        /// never synced, never in the backup, and cleared by Erase All Data.
        public static let weeklySweepLastSweptAt = "weeklySweepLastSweptAt"
        public static let weeklySweepReminder = "weeklySweepReminder"
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

/// Persistence for the per-device escalation window. Stored as days, with 0 meaning Off;
/// absent or unrecognised values fall back to the 2-day default (spec-escalation §4).
extension EscalationWindow {
    public static func load(from defaults: UserDefaults = AppGroupDefaults.shared) -> EscalationWindow {
        guard let stored = defaults.object(forKey: AppGroupDefaults.Key.escalationWindowDays) as? Int,
              let window = EscalationWindow(rawValue: stored) else { return .default }
        return window
    }

    public func save(to defaults: UserDefaults = AppGroupDefaults.shared) {
        defaults.set(rawValue, forKey: AppGroupDefaults.Key.escalationWindowDays)
    }
}
