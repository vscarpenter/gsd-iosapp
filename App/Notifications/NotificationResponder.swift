import UIKit
import UserNotifications
import GSDSnapshot

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
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        // Only a tap (default action) opens the task — a swipe-away dismiss must not navigate.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let taskID = response.notification.request.content.userInfo["taskID"] as? String
        else { return }
        DeepLinkHandoff.open(.task(taskID))
    }
}
