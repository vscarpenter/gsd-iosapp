import Foundation
import os
import GSDStore
import UIKit

/// Delivers a tapped reminder button to the store. The store is built in `GSDApp.init`, but a
/// button tap can cold-launch the app in the background, so a response may reach the
/// notification delegate before the store exists. Responses wait here until `attach` runs.
/// The delegate's completion handler fires only after the store write finishes, which is
/// what keeps a background-launched process alive long enough to save.
@MainActor
enum ReminderActionInbox {
    private struct Pending { let action: String; let taskID: String; let done: () -> Void }

    private static let log = Logger(subsystem: "dev.vinny.gsd", category: "reminder-actions")
    private static var handler: ReminderActionHandler?
    private static var waiting: [Pending] = []
    /// One action at a time: each opens and closes the database, and the database is process-wide.
    private static var lastAction: _Concurrency.Task<Void, Never>?

    static func attach(store: TaskStore) {
        handler = ReminderActionHandler(store: store, isBackgrounded: isBackgrounded)
        let queued = waiting
        waiting.removeAll()
        queued.forEach(run)
    }

    /// Mac Catalyst never suspends the database (see `withDatabaseResumedForIntent`), and a Mac app
    /// is routinely `.inactive` with its window live, so the iOS check would misread it.
    private static func isBackgrounded() -> Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIApplication.shared.applicationState != .active
        #endif
    }

    static func deliver(action: String, taskID: String, done: @escaping () -> Void) {
        let item = Pending(action: action, taskID: taskID, done: done)
        if handler == nil { waiting.append(item) } else { run(item) }
    }

    private static func run(_ item: Pending) {
        guard let handler else { return }
        let previous = lastAction
        lastAction = _Concurrency.Task { @MainActor in
            await previous?.value
            defer { item.done() }
            do {
                _ = try await handler.handle(actionIdentifier: item.action, taskID: item.taskID)
            } catch {
                log.error("Reminder action \(item.action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
