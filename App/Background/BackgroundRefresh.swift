import Foundation
import BackgroundTasks
import GSDStore

/// Background app-refresh (product spec §9.4): drains the Share-Extension outbox, runs one sync,
/// then the trash and auto-archive sweeps + badge refresh so data is fresh on next open.
///
/// The drain + sync is what lets a task shared from Safari reach the server without the app being
/// opened: on iOS the extension never foregrounds GSD, so the launch/foreground drains in `GSDApp`
/// don't fire until the user comes back. This window is the only app-side code that runs in between
/// (the OS decides when; see `schedule()`). The signed-in auto-archive sweep hangs off
/// `SyncCoordinator.afterCleanSync`, so it runs here only once the sync has pulled: archiving
/// deletes the server copy (parity B-43) and must never act on a stale local copy. Signed out, the
/// sweep runs directly. NOT relied on for timely reminders (those are pre-scheduled, §9.1).
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
    ///
    /// `drainShareInbox` materializes pending Share-Extension captures through the store's create
    /// path; `sync` runs one full sync (`SyncCoordinator.backgroundSync`, a no-op when signed out).
    @MainActor
    static func register(store: TaskStore,
                         signedIn: @escaping @MainActor @Sendable () -> Bool,
                         drainShareInbox: @escaping @MainActor @Sendable () async -> Void,
                         sync: @escaping @MainActor @Sendable () async -> Void) {
        #if !targetEnvironment(macCatalyst)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: .main) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { task.setTaskCompleted(success: false); return }
            handle(refreshTask, store: store, signedIn: signedIn, drainShareInbox: drainShareInbox, sync: sync)
        }
        #endif
        // On Mac Catalyst there is no BGTaskScheduler: foreground refresh (GSDApp `.task`)
        // and SyncCoordinator's cadence timer cover the same freshness need.
    }

    /// Submit the next refresh request (earliest ~15 minutes out — the OS decides actual timing).
    static func schedule() {
        #if !targetEnvironment(macCatalyst)
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #endif
    }

    #if !targetEnvironment(macCatalyst)
    @MainActor
    private static func handle(_ task: BGAppRefreshTask, store: TaskStore,
                               signedIn: @escaping @MainActor @Sendable () -> Bool,
                               drainShareInbox: @escaping @MainActor @Sendable () async -> Void,
                               sync: @escaping @MainActor @Sendable () async -> Void) {
        schedule()   // always queue the next one
        let work = _Concurrency.Task { @MainActor in
            // The database was suspended on backgrounding (0xDEAD10CC mitigation). Resume it for
            // this background window, then re-suspend so we never hold a lock when the OS suspends
            // us again after setTaskCompleted.
            AppDatabase.resume()
            // Shared captures first, so the sync that follows pushes them in the same window.
            await drainShareInbox()
            if signedIn() {
                await sync()                                   // pull + push; afterCleanSync runs the archive sweep
            } else {
                try? await store.runAutoArchiveSweep()         // see the type comment
            }
            _ = try? await store.runTrashRetentionSweep()
            await store.refreshBadge()
            AppDatabase.suspend()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            AppDatabase.suspend()
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}
