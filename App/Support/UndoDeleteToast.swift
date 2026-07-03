import SwiftUI
import GSDModel
import GSDStore

extension Notification.Name {
    /// Posted by `TaskActions.delete` after the store commits, carrying the deleted `Task`
    /// snapshot as the notification object so the root undo toast can offer restore.
    static let gsdTaskDeleted = Notification.Name("dev.vinny.gsd.taskDeleted")
}

/// Bottom "Deleted — Undo" capsule hosted once at the root (`ContentView`), so a delete
/// from any surface (matrix swipe, `⋯` menu, Browse row, VoiceOver custom action) offers
/// the same ~6-second recovery window — the calm alternative to a confirmation dialog
/// (design critique P2, 2026-07-02).
///
/// Undo re-creates the task snapshot rather than blocking the delete: the delete's
/// tombstone is already enqueued by `TaskStore.delete`, and the follow-up create wins
/// last-write-wins on the server, so restore is safe online and offline.
struct UndoDeleteToast: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var deleted: Task?
    @State private var failure: TaskActionFailure?

    var body: some View {
        Group {
            if let task = deleted {
                HStack(spacing: 14) {
                    Text(String(localized: "Deleted “\(task.title)”"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(String(localized: "Undo")) { restore(task) }
                        .fontWeight(.bold)
                        .foregroundStyle(Surface.paper)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Surface.paper)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(Surface.ink, in: Capsule())
                .shadow(color: Surface.shadow.opacity(0.18), radius: 12, x: 0, y: 5)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task(id: task.id) {
                    // VoiceOver users navigate slower than sighted users tap — hold longer.
                    let seconds: Double = UIAccessibility.isVoiceOverRunning ? 12 : 6
                    try? await _Concurrency.Task.sleep(for: .seconds(seconds))
                    withAnimation { if deleted?.id == task.id { deleted = nil } }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gsdTaskDeleted)) { note in
            guard let task = note.object as? Task else { return }
            withAnimation { deleted = task }
            UIAccessibility.post(
                notification: .announcement,
                argument: String(localized: "Deleted \(task.title). Undo is available."))
        }
        .taskActionFailureAlert($failure)
    }

    private func restore(_ task: Task) {
        withAnimation { deleted = nil }
        _Concurrency.Task { @MainActor in
            do {
                try await store.create(task)
            } catch {
                failure = TaskActionFailure(String(localized: "Couldn’t restore that task"))
            }
        }
    }
}
