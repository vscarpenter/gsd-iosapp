import Foundation
import WidgetKit
import GSDStore
import GSDSnapshot

/// Writes the Today's Focus snapshot whenever the task set changes, coalescing bursts
/// (a bulk pull/import emits many changes) into one write + timeline reload (spec §6).
@MainActor
final class WidgetSnapshotRefresher {
    private let store: TaskStore
    private let snapshotStore: WidgetSnapshotStore
    private let now: () -> Date
    private let debounce: Duration
    private var debounceTask: _Concurrency.Task<Void, Never>?

    init(store: TaskStore,
         snapshotStore: WidgetSnapshotStore = WidgetSnapshotStore(),
         now: @escaping () -> Date = { Date() },
         debounce: Duration = .seconds(1)) {
        self.store = store
        self.snapshotStore = snapshotStore
        self.now = now
        self.debounce = debounce
    }

    /// Trigger the first snapshot via the debounce — NOT a synchronous write. At launch
    /// `store.tasks` is still `[]` (the GRDB observer emits its initial value asynchronously,
    /// after `store.start()`), so a synchronous write here would clobber the last-good
    /// snapshot with an empty one and flash "All clear". Going through `schedule()` means the
    /// observer's first emission populates `tasks` (and itself fires `schedule()`), so the
    /// debounced write always sees real data.
    func start() { schedule() }

    /// Coalesce a burst of task changes into a single delayed write + reload.
    func schedule() {
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: self.debounce)
            if _Concurrency.Task.isCancelled { return }
            self.writeNow()
        }
    }

    private func writeNow() {
        let snapshot = WidgetSnapshotBuilder.todaysFocus(from: store.tasks, now: now())
        do { try snapshotStore.write(snapshot) } catch { return }  // no container ⇒ skip, never crash
        WidgetCenter.shared.reloadAllTimelines()
    }
}
