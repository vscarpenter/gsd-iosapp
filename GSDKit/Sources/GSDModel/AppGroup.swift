import Foundation

/// The App Group container shared by the app and its extensions (widgets in Phase 6a).
/// This is the single source of truth for the identifier; it MUST match the
/// `com.apple.security.application-groups` entitlement in every target.
public enum AppGroup {
    public static let id = "group.dev.vinny.gsd"
    /// `UserDefaults(suiteName: id)` key for the stable per-device sync identity (`DeviceIdentity`
    /// in GSDStore writes it; the GRDB-free Share Extension reads it to stamp a direct push).
    public static let deviceIDKey = "deviceId"
    /// `UserDefaults(suiteName: id)` key for the Default reminder (minutes before due). The app's
    /// `AppGroupDefaults` and the GRDB-free Share Extension both read it, so the key lives here.
    public static let defaultReminderKey = "notificationDefaultReminder"
    /// The seeded Default reminder when none is stored.
    public static let fallbackDefaultReminder = 15
}
