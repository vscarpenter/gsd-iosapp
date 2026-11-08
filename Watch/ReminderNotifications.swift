import SwiftUI
import UserNotifications
import WatchKit
import GSDModel
import GSDSnapshot

/// Reminders on the watch (spec 4.4). The iPhone schedules every reminder; the watch only
/// draws the ones it is handed, names the same category and two actions, and turns a button
/// press into a `WatchCommand` the iPhone applies. When the iPhone receives the press instead
/// (open item 2), it takes the existing `ReminderActionInbox` path and nothing here runs.
final class WatchAppDelegate: NSObject, WKApplicationDelegate, @preconcurrency UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.reminderCategory])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? String else { return }
        let model = WatchModel.shared
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            model.open(taskID: taskID)   // Only a tap opens the task; a dismiss must not navigate.
        } else if let kind = WatchReminderRoute.kind(forAction: response.actionIdentifier, taskID: taskID) {
            model.start()                // A button press can launch the app in the background.
            model.queue(kind)
        }
    }

    /// Same category and buttons as the iPhone's, without `.foreground`: neither opens the app.
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

/// The GSD notification scene: the reminder's title, then quadrant, due time, and the
/// escalation marker when one applies. Shown instead of the default long look.
final class ReminderNotificationController: WKUserNotificationHostingController<ReminderNotificationView> {
    private var title = ""
    private var taskID: String?

    override var body: ReminderNotificationView { ReminderNotificationView(title: title, taskID: taskID) }

    override func didReceive(_ notification: UNNotification) {
        let content = notification.request.content
        title = content.title
        taskID = content.userInfo["taskID"] as? String
    }
}

struct ReminderNotificationView: View {
    let title: String
    let taskID: String?

    var body: some View {
        let card = taskID.flatMap {
            WatchReminderRoute.card(for: $0, in: WatchModel.shared.snapshot, now: .now, timeZone: .current)
        }
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            if let card {
                Text(card.quadrant.title)
                if let due = card.dueDate {
                    Text("Due \(due.formatted(date: .abbreviated, time: .shortened))")
                }
                if card.escalation.escalating, let days = card.escalation.daysUntilDue {
                    Label(Escalation.accessibilityLabel(daysUntilDue: days), systemImage: "exclamationmark")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}
