import Foundation

/// Notification configuration singleton (product spec §5.4). A `Sendable` value type in
/// `GSDModel` so the App's live scheduler can read it without importing `GSDStore`; the
/// store persists it in App-Group `UserDefaults` (mirrors `ArchiveSettings`). `quietHours*`
/// are `"HH:mm"` local-time strings (nil = that bound unset → no quiet window).
public struct NotificationSettings: Equatable, Sendable {
    public var enabled: Bool                 // global reminder master switch
    public var defaultReminder: Int          // minutes before due; one of `allowedReminders`
    public var soundEnabled: Bool
    public var quietHoursStart: String?      // "HH:mm"
    public var quietHoursEnd: String?        // "HH:mm"
    public var permissionAsked: Bool         // whether the OS prompt was shown

    /// The offered default-reminder presets (§5.4): 15m, 30m, 1h, 2h, 1 day.
    public static let allowedReminders = [15, 30, 60, 120, 1440]

    public init(enabled: Bool = true, defaultReminder: Int = 15, soundEnabled: Bool = true,
                quietHoursStart: String? = nil, quietHoursEnd: String? = nil,
                permissionAsked: Bool = false) {
        self.enabled = enabled
        self.defaultReminder = NotificationSettings.allowedReminders.contains(defaultReminder) ? defaultReminder : 15
        self.soundEnabled = soundEnabled
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
        self.permissionAsked = permissionAsked
    }
}
