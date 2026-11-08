import Foundation
import GSDModel

/// The two per-device weekly sweep values (spec-weekly-sweep section 6), kept in App-Group
/// `UserDefaults`. They stay outside sync and outside the backup envelope, like the escalation
/// window. `TaskStore.eraseAllData` calls `reset` so Erase All Data clears both.
public enum WeeklySweepSettings {
    /// Turning the reminder on starts here: Sunday 09:00.
    public static let defaultReminder = WeeklySweep.Reminder(enabled: true, weekday: 7, hour: 9, minute: 0)

    /// The reminder with its switch flipped and its day and time kept, so turning it back on
    /// returns to the last choice. A never-set reminder reads as `.off`, which already holds
    /// Sunday 09:00, so the first turn-on starts there.
    public static func toggled(_ reminder: WeeklySweep.Reminder, on: Bool) -> WeeklySweep.Reminder {
        var next = reminder
        next.enabled = on
        return next
    }

    public static func lastSweptAt(from defaults: UserDefaults = AppGroupDefaults.shared) -> Date? {
        defaults.object(forKey: AppGroupDefaults.Key.weeklySweepLastSweptAt) as? Date
    }

    /// Stamped when the user reaches the end or taps Done. Leaving another way stamps nothing.
    public static func stampSwept(at date: Date, in defaults: UserDefaults = AppGroupDefaults.shared) {
        defaults.set(date, forKey: AppGroupDefaults.Key.weeklySweepLastSweptAt)
    }

    /// Stored as `[enabled, weekday, hour, minute]`. Anything unrecognised reads as off.
    public static func reminder(from defaults: UserDefaults = AppGroupDefaults.shared) -> WeeklySweep.Reminder {
        guard let raw = defaults.array(forKey: AppGroupDefaults.Key.weeklySweepReminder) as? [Int],
              raw.count == 4, raw[0] == 0 || raw[0] == 1,
              (1...7).contains(raw[1]), (0...23).contains(raw[2]), (0...59).contains(raw[3])
        else { return .off }
        return WeeklySweep.Reminder(enabled: raw[0] == 1, weekday: raw[1], hour: raw[2], minute: raw[3])
    }

    public static func setReminder(_ reminder: WeeklySweep.Reminder,
                                   in defaults: UserDefaults = AppGroupDefaults.shared) {
        defaults.set([reminder.enabled ? 1 : 0, reminder.weekday, reminder.hour, reminder.minute],
                     forKey: AppGroupDefaults.Key.weeklySweepReminder)
    }

    public static func reset(in defaults: UserDefaults = AppGroupDefaults.shared) {
        defaults.removeObject(forKey: AppGroupDefaults.Key.weeklySweepLastSweptAt)
        defaults.removeObject(forKey: AppGroupDefaults.Key.weeklySweepReminder)
    }
}
