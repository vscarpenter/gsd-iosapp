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
        }
    }

    func move(_ t: Task, to q: Quadrant) {
        run(String(localized: "Couldn’t move that task")) {
            try await store.move(t, to: q)
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

    private func run(
        _ failureMessage: String,
        operation: @escaping () async throws -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        _Concurrency.Task { @MainActor in
            do {
                try await operation()
                onSuccess()
            } catch {
                onError("\(failureMessage): \(error.localizedDescription)")
            }
        }
    }
}

struct TaskActionFailure: Identifiable, Equatable {
    let id = UUID()
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

extension View {
    @MainActor
    func taskActionFailureAlert(_ failure: Binding<TaskActionFailure?>) -> some View {
        alert(String(localized: "Action failed"),
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
