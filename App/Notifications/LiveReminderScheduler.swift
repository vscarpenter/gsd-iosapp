import Foundation
import UserNotifications
import GSDModel
import GSDStore

/// The live `ReminderScheduling` implementation (product spec §9). Lives in the App target —
/// the only layer that imports `UserNotifications`. Owns the scheduling math (`ReminderMath` +
/// quiet hours), reads `NotificationSettings` via an injected closure (so it needn't reach into
/// the store's internals), and uses the stable id `task-<id>` so a reschedule REPLACES rather
/// than stacks. `@unchecked Sendable`: `UNUserNotificationCenter.current()` is a thread-safe
/// singleton and the injected closure is `@Sendable`; the type holds no mutable state.
final class LiveReminderScheduler: ReminderScheduling, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()
    private let settingsProvider: @Sendable () -> NotificationSettings
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    init(settingsProvider: @escaping @Sendable () -> NotificationSettings,
         calendar: Calendar = .current,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.settingsProvider = settingsProvider
        self.calendar = calendar
        self.now = now
    }

    func schedule(_ task: Task) async {
        let id = identifier(for: task.id)
        let settings = settingsProvider()
        // A snoozed task fires at snoozedUntil (if still future); otherwise normal fireDate.
        let baseFire: Date?
        if let snoozed = task.snoozedUntil, snoozed > now(), !task.completed, settings.enabled, task.notificationEnabled {
            baseFire = snoozed
        } else {
            let inputs = ReminderMath.Inputs(masterEnabled: settings.enabled, defaultReminder: settings.defaultReminder)
            baseFire = ReminderMath.fireDate(for: task, inputs: inputs, now: now())
        }
        guard let fire = baseFire else {
            // Nothing to fire → ensure no stale pending request lingers.
            center.removePendingNotificationRequests(withIdentifiers: [id])
            return
        }
        let deferred = ReminderMath.applyQuietHours(fire, quietStart: settings.quietHoursStart,
                                                    quietEnd: settings.quietHoursEnd, calendar: calendar)

        let content = UNMutableNotificationContent()
        content.title = task.title
        if !task.description.isEmpty { content.body = task.description }
        content.sound = settings.soundEnabled ? .default : nil
        content.userInfo = ["taskID": task.id]

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: deferred)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        // Replace any existing pending request for this id, then add.
        center.removePendingNotificationRequests(withIdentifiers: [id])
        do { try await center.add(request) } catch { /* delivery is best-effort; ignore add failure */ }
    }

    func cancel(taskID: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [identifier(for: taskID)])
    }

    func cancelAll() async {
        center.removeAllPendingNotificationRequests()
    }

    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool {
        let current = await center.notificationSettings()
        switch current.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            return granted
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func setBadge(_ count: Int) async {
        try? await center.setBadgeCount(count)
    }

    private func identifier(for taskID: String) -> String { "task-\(taskID)" }
}
