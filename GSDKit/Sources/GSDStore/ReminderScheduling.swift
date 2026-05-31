import Foundation
import GSDModel

/// The store's reminder-orchestration seam (product spec §9.1). The store calls these on
/// the §9.1 mutation events but never imports `UserNotifications` — the live implementation
/// lives in the App target (`LiveReminderScheduler`). `async` because `UNUserNotificationCenter`
/// is async. `Sendable` so a default instance can be a defaulted `init` argument.
public protocol ReminderScheduling: Sendable {
    /// (Re)schedule the task's local reminder. The implementation computes the fire time
    /// (`ReminderMath` + quiet hours), using the stable id `task-<id>` so a reschedule REPLACES
    /// the pending request. If the task shouldn't fire (disabled/completed/no-due/past), the
    /// implementation cancels any pending request for that id instead.
    func schedule(_ task: Task) async

    /// Cancel the pending reminder for a task (completion / delete / disable).
    func cancel(taskID: String) async

    /// Cancel every pending reminder (used by a full reset).
    func cancelAll() async

    /// Request notification authorization if not already determined (contextual — product
    /// spec §9.2). No-op if already asked/granted/denied. Returns whether reminders are
    /// authorized after the call.
    @discardableResult
    func requestAuthorizationIfNeeded() async -> Bool

    /// Set the app-icon badge (product spec §9.4).
    func setBadge(_ count: Int) async
}

/// The default no-op scheduler so existing `TaskStore` call sites and tests compile and run
/// unchanged (the live scheduler is injected only by the App). Every method is an async no-op.
public struct NoopReminderScheduler: ReminderScheduling {
    public init() {}
    public func schedule(_ task: Task) async {}
    public func cancel(taskID: String) async {}
    public func cancelAll() async {}
    public func requestAuthorizationIfNeeded() async -> Bool { false }
    public func setBadge(_ count: Int) async {}
}
