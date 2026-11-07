import SwiftUI
import GSDModel
import GSDStore

/// Bundles the row mutation handlers so the iPhone section and iPad cell share them.
@MainActor
struct TaskActions {
    let store: TaskStore
    let onCompleted: () -> Void   // fire confetti when a task becomes complete
    let onError: (String) -> Void

    init(
        store: TaskStore,
        onCompleted: @escaping () -> Void,
        onError: @escaping (String) -> Void = { _ in }
    ) {
        self.store = store
        self.onCompleted = onCompleted
        self.onError = onError
    }

    func toggle(_ t: Task) {
        let willComplete = !t.completed
        run(String(localized: "Couldn’t update that task")) {
            try await store.toggleComplete(t)
        } onSuccess: {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            if willComplete { onCompleted() }
        }
    }

    func delete(_ t: Task) {
        run(String(localized: "Couldn’t delete that task")) {
            try await store.delete(t)
        } onSuccess: {
            // The root UndoTaskToast listens and offers a recovery window; delete
            // itself commits immediately (tombstone-safe), so this is fire-and-forget.
            NotificationCenter.default.post(name: .gsdTaskDeleted, object: t)
        }
    }

    func move(_ t: Task, to q: Quadrant) {
        run(String(localized: "Couldn’t move that task")) {
            try await store.move(t, to: q)
        }
    }

    /// Escalation's one action: set urgent through the ordinary move, then offer Undo.
    /// No celebration; the card simply changes quadrant.
    func markUrgent(_ t: Task, target: Escalation.Target) {
        run(String(localized: "Couldn’t mark that task urgent")) {
            try await store.move(t, to: target.quadrant)
        } onSuccess: {
            NotificationCenter.default.post(name: .gsdTaskMarkedUrgent, object: t)
        }
    }

    func moveToSaved(_ task: Task) {
        run(String(localized: "Couldn’t move that task to Saved")) {
            let saved = try await store.moveToSaved(task)
            NotificationCenter.default.post(name: .gsdTaskSaved, object: saved)
        }
    }

    func duplicate(_ t: Task) {
        run(String(localized: "Couldn’t duplicate that task")) {
            _ = try await store.duplicate(t)
        }
    }

    func snooze(_ t: Task, by preset: SnoozePreset) {
        run(String(localized: "Couldn’t snooze that task")) {
            try await store.snooze(t, by: preset)
        }
    }

    func startTimer(_ t: Task) {
        run(String(localized: "Couldn’t start the timer")) {
            try await store.startTimer(t)
        }
    }

    func stopTimer(_ t: Task) {
        run(String(localized: "Couldn’t stop the timer")) {
            try await store.stopTimer(t)
        }
    }

    // MARK: Top three (D-13)
    // Each is an ordinary edit through `store.save`, which stamps `updatedAt` and queues the push.
    // Nothing here writes at midnight or on its own.

    func addToToday(_ t: Task) {
        run(TodayError.add, appendDetail: false) {
            let now = Date(), zone = TimeZone.current
            guard let rank = TopThree.nextRank(store.tasks, now: now, timeZone: zone) else { return }
            try await setFocus(id: t.id, date: TopThree.localDate(now, timeZone: zone), rank: rank)
        }
    }

    func removeFromToday(_ t: Task) {
        run(TodayError.remove, appendDetail: false) {
            try await setFocus(id: t.id, date: nil, rank: nil)
        }
    }

    /// Swaps ranks with the neighbor. Offered only while there is nothing to tidy.
    func moveInToday(_ t: Task, by delta: Int) {
        run(TodayError.reorder, appendDetail: false) {
            let picks = TopThree.todaysPicks(store.tasks, now: Date(), timeZone: .current)
            guard !picks.needsTidy, let index = picks.picks.firstIndex(of: t.id),
                  picks.picks.indices.contains(index + delta),
                  let mine = store.tasks.first(where: { $0.id == t.id }),
                  let other = store.tasks.first(where: { $0.id == picks.picks[index + delta] })
            else { return }
            try await setFocus(id: mine.id, date: mine.focusDate, rank: other.focusRank)
            try await setFocus(id: other.id, date: other.focusDate, rank: mine.focusRank)
        }
    }

    /// Accepting "Tidy up?" only. Rows already correct aren't written.
    func tidyToday() {
        run(TodayError.tidy, appendDetail: false) {
            for write in TopThree.tidy(store.tasks, now: Date(), timeZone: .current) {
                try await setFocus(id: write.id, date: write.focusDate, rank: write.focusRank)
            }
        }
    }

    private func setFocus(id: String, date: String?, rank: Int?) async throws {
        guard var current = store.tasks.first(where: { $0.id == id }) else { return }
        current.focusDate = date
        current.focusRank = rank
        try await store.save(current)
    }

    private func run(
        _ failureMessage: String,
        appendDetail: Bool = true,
        operation: @escaping () async throws -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        _Concurrency.Task { @MainActor in
            do {
                try await operation()
                onSuccess()
            } catch {
                onError(appendDetail ? "\(failureMessage): \(error.localizedDescription)" : failureMessage)
            }
        }
    }
}

/// The top three errors, in web's words. No top three error says "failed", so these get a title
/// without it too (`TaskActionFailure.title`) and carry no raw error text.
enum TodayError {
    static let add = String(localized: "Couldn’t add to today. Try again.")
    static let remove = String(localized: "Couldn’t remove that from today. Try again.")
    static let reorder = String(localized: "Couldn’t reorder today. Try again.")
    static let tidy = String(localized: "Couldn’t tidy today. Try again.")
    static var all: Set<String> { [add, remove, reorder, tidy] }
}

struct TaskActionFailure: Identifiable, Equatable {
    let id = UUID()
    let message: String
    /// "Today" for a top three error, so the alert never reads "Action failed" over it.
    let title: String

    init(_ message: String) {
        self.message = message
        self.title = TodayError.all.contains(message) ? String(localized: "Today") : String(localized: "Action failed")
    }
}

extension View {
    @MainActor
    func taskActionFailureAlert(_ failure: Binding<TaskActionFailure?>) -> some View {
        alert(failure.wrappedValue?.title ?? String(localized: "Action failed"),
              isPresented: Binding(get: { failure.wrappedValue != nil },
                                   set: { if !$0 { failure.wrappedValue = nil } })) {
            Button(String(localized: "OK"), role: .cancel) {
                failure.wrappedValue = nil
            }
        } message: {
            Text(failure.wrappedValue?.message ?? "")
        }
    }
}
