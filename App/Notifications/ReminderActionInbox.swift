import Foundation
import os
import GSDStore

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

    static func attach(store: TaskStore) {
        handler = ReminderActionHandler(store: store)
        let queued = waiting
        waiting.removeAll()
        queued.forEach(run)
    }

    static func deliver(action: String, taskID: String, done: @escaping () -> Void) {
        let item = Pending(action: action, taskID: taskID, done: done)
        if handler == nil { waiting.append(item) } else { run(item) }
    }

    private static func run(_ item: Pending) {
        guard let handler else { return }
        _Concurrency.Task { @MainActor in
            defer { item.done() }
            do {
                _ = try await handler.handle(actionIdentifier: item.action, taskID: item.taskID)
            } catch {
                log.error("Reminder action \(item.action, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
