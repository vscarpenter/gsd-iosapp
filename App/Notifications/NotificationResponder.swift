import UIKit
import UserNotifications
import GSDSnapshot
import GSDStore

/// Routes a tapped reminder to its task. Reminders are scheduled with the task id in
/// `userInfo["taskID"]` (`LiveReminderScheduler`), but nothing consumed it: with no
/// `UNUserNotificationCenterDelegate`, tapping a reminder only foregrounded the app to its last
/// screen. We register the delegate at launch — early enough to catch a tap that *cold-launches*
/// the app — and forward the tap through the same `DeepLinkHandoff` plumbing the widgets,
/// Spotlight, and quick actions already use. `DeepLinkHandoff.open` posts live AND persists the
/// URL as a cold-launch fallback (`ContentView.consumePendingURL`), so both warm and cold taps
/// land on the task.
// `@preconcurrency`: `UNUserNotificationCenterDelegate` isn't `@MainActor`-annotated in the SDK,
// but its callbacks are delivered on the main thread, so the @MainActor `AppDelegate` can satisfy
// it safely (the compiler inserts a main-actor check at the dispatch boundary).
extension AppDelegate: @preconcurrency UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().setNotificationCategories([Self.reminderCategory])
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? String else {
            completionHandler()
            return
        }
        switch response.actionIdentifier {
        case ReminderAction.completeID, ReminderAction.snoozeID:
            // The system keeps a background launch alive until this handler is called, so hold it
            // until the store write lands.
            ReminderActionInbox.deliver(action: response.actionIdentifier, taskID: taskID, done: completionHandler)
        case UNNotificationDefaultActionIdentifier:
            // Only a tap opens the task. A swipe-away dismiss must not navigate.
            DeepLinkHandoff.open(.task(taskID))
            completionHandler()
        default:
            completionHandler()
        }
    }

    /// The buttons under a reminder: Complete and Snooze 1 hour (B-17). No `.foreground`, so
    /// neither opens the app; both act in place through `ReminderActionInbox`.
    private static var reminderCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: ReminderAction.categoryID,
            actions: [
                UNNotificationAction(identifier: ReminderAction.completeID,
                                     title: String(localized: "Complete"), options: []),
                UNNotificationAction(identifier: ReminderAction.snoozeID,
                                     title: String(localized: "Snooze 1 hour"), options: []),
            ],
            intentIdentifiers: [])
    }
}
