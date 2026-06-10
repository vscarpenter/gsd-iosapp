import Foundation
import GSDStore

/// Debounced reminder resync — the reminder counterpart of `WidgetSnapshotRefresher`
/// (design 2026-06-10 Fix A). Fired from `TaskStore.onTasksChanged`, so the GRDB observer's
/// initial emission doubles as the launch sweep (no `start()`: sweeping before the first
/// emission would cancelAll against an empty snapshot and briefly wipe live reminders).
@MainActor
final class ReminderResyncer {
    private let store: TaskStore
    private let debounce: Duration
    private var debounceTask: _Concurrency.Task<Void, Never>?

    init(store: TaskStore, debounce: Duration = .seconds(1)) {
        self.store = store
        self.debounce = debounce
    }

    /// Coalesce a burst of task changes (bulk pull/import) into one sweep.
    func schedule() {
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: self.debounce)
            if _Concurrency.Task.isCancelled { return }
            await self.store.resyncReminders()
        }
    }
}
