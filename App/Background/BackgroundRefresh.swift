import Foundation
import BackgroundTasks
import GSDStore

/// Background app-refresh (product spec §9.4): runs the auto-archive sweep + badge refresh so
/// data is fresh on next open. NOT relied on for timely reminders (those are pre-scheduled, §9.1).
/// The identifier must match `project.yml`'s `BGTaskSchedulerPermittedIdentifiers`.
enum BackgroundRefresh {
    static let taskIdentifier = "dev.vinny.gsd.refresh"

    /// Register the handler — call ONCE, early in app launch (before the scene appears).
    ///
    /// The launch handler MUST run on `.main`: it synchronously calls the `@MainActor` `handle`,
    /// so the closure is main-actor-isolated and Swift 6 asserts the executor at call time. Passing
    /// `using: nil` runs the handler on a background queue, tripping `dispatch_assert_queue(main)`
    /// and crashing the moment the OS fires the task. `.main` keeps the non-Sendable `BGTask` on the
    /// main actor throughout; `handle` does only trivial sync work and offloads the real work to a Task.
    @MainActor
    static func register(store: TaskStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(refreshTask, store: store)
        }
    }

    /// Submit the next refresh request (earliest ~15 minutes out — the OS decides actual timing).
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    private static func handle(_ task: BGAppRefreshTask, store: TaskStore) {
        schedule()   // always queue the next one
        let work = _Concurrency.Task { @MainActor in
            // The database was suspended on backgrounding (0xDEAD10CC mitigation). Resume it for
            // this background window, then re-suspend so we never hold a lock when the OS suspends
            // us again after setTaskCompleted.
            AppDatabase.resume()
            try? await store.runAutoArchiveSweep()
            await store.refreshBadge()
            // NOTE (Phase 5): perform an opportunistic sync here so data is fresh on next open.
            AppDatabase.suspend()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            AppDatabase.suspend()
            task.setTaskCompleted(success: false)
        }
    }
}
