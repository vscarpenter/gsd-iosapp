/// Identifiers for the buttons on a reminder notification (B-17). Strings only, so the iPhone
/// app and the watch app can each build their `UNNotificationCategory` from one source without
/// this module importing `UserNotifications`. The values never change: reminders already
/// scheduled on a device match their category and actions by these strings.
public enum ReminderAction {
    public static let categoryID = "dev.vinny.gsd.reminder"
    public static let completeID = "dev.vinny.gsd.reminder.complete"
    public static let snoozeID = "dev.vinny.gsd.reminder.snooze1h"
}
