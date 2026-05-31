import SwiftUI
import GSDModel
import GSDStore

/// Bundles the row mutation handlers so the iPhone section and iPad cell share them.
@MainActor
struct TaskActions {
    let store: TaskStore
    let onCompleted: () -> Void   // fire confetti when a task becomes complete

    func toggle(_ t: Task) {
        let willComplete = !t.completed
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        _Concurrency.Task { try? await store.toggleComplete(t); if willComplete { onCompleted() } }
    }
    func delete(_ t: Task) { _Concurrency.Task { try? await store.delete(t) } }
    func move(_ t: Task, to q: Quadrant) { _Concurrency.Task { try? await store.move(t, to: q) } }
    func snooze(_ t: Task, by preset: SnoozePreset) {
        _Concurrency.Task { try? await store.snooze(t, by: preset) }
    }
    func startTimer(_ t: Task) { _Concurrency.Task { try? await store.startTimer(t) } }
    func stopTimer(_ t: Task)  { _Concurrency.Task { try? await store.stopTimer(t) } }
}
