import Foundation
import BackgroundTasks
import GSDStore

/// Background app-refresh (product spec §9.4): runs the auto-archive sweep + badge refresh so
/// data is fresh on next open. NOT relied on for timely reminders (those are pre-scheduled, §9.1).
/// The identifier must match `project.yml`'s `BGTaskSchedulerPermittedIdentifiers`.
enum BackgroundRefresh {
    static let taskIdentifier = "dev.vinny.gsd.refresh"

    /// Register the handler — call ONCE, early in app launch (before the scene appears).
    @MainActor
    static func register(store: TaskStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
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
            try? await store.runAutoArchiveSweep()
            await store.refreshBadge()
            // NOTE (Phase 5): perform an opportunistic sync here so data is fresh on next open.
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel(); task.setTaskCompleted(success: false) }
    }
}
