import SwiftUI
import GSDModel
import GSDStore

extension Notification.Name {
    /// Posted by `TaskActions.delete` after the store commits, carrying the deleted `Task`
    /// snapshot as the notification object so the root undo window can offer restore.
    static let gsdTaskDeleted = Notification.Name("dev.vinny.gsd.taskDeleted")
}

/// Root-owned state for the "Deleted, Undo" recovery window that a delete from any surface
/// (matrix swipe, `⋯` menu, Browse row, VoiceOver custom action) opens for about six seconds,
/// the calm alternative to a confirmation dialog (design critique P2, 2026-07-02).
///
/// Undo re-creates the task snapshot rather than blocking the delete: the delete's tombstone
/// is already enqueued by `TaskStore.delete`, and the follow-up create wins last-write-wins
/// on the server, so restore is safe online and offline.
@MainActor @Observable
final class UndoDeleteController {
    private(set) var deleted: Task?
    var failure: TaskActionFailure?
    private var expiry: _Concurrency.Task<Void, Never>?

    /// Opens the window for `task` and schedules its close.
    func noteDeleted(_ task: Task) {
        withAnimation { deleted = task }
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "Deleted \(task.title). Undo is available."))
        expiry?.cancel()
        expiry = _Concurrency.Task { [weak self] in
            // VoiceOver users navigate slower than sighted users tap: hold longer.
            let seconds: Double = UIAccessibility.isVoiceOverRunning ? 12 : 6
            try? await _Concurrency.Task.sleep(for: .seconds(seconds))
            guard !_Concurrency.Task.isCancelled, let self, self.deleted?.id == task.id else { return }
            withAnimation { self.deleted = nil }
        }
    }

    func restore(into store: TaskStore) {
        guard let task = deleted else { return }
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

/// The ink capsule for the regular root (iPad, Mac), overlaid above the bottom edge.
struct UndoDeleteToast: View {
    let undo: UndoDeleteController
    @Environment(TaskStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let task = undo.deleted {
            HStack(spacing: 14) {
                Text(String(localized: "Deleted “\(task.title)”"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button(String(localized: "Undo")) { undo.restore(into: store) }
                    .fontWeight(.bold)
                    .foregroundStyle(Surface.paper)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Surface.paper)
            .padding(.horizontal, 18).padding(.vertical, 12)
            .background(Surface.ink, in: Capsule())
            .shadow(color: Surface.shadow.opacity(0.18), radius: 12, x: 0, y: 5)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// The compact counterpart: the tab bar's bottom accessory (iOS 26). The system draws the
/// glass, keeps the accessory clear of the bar, and folds it beside the bar when the bar
/// minimizes on scroll, which retires the old fixed 72-point clearance. Expanded: the title
/// and Undo; inline (beside the minimized bar): Undo alone.
struct UndoDeleteAccessory: View {
    let undo: UndoDeleteController
    @Environment(TaskStore.self) private var store
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let task = undo.deleted {
            HStack(spacing: 12) {
                if placement != .inline {
                    Text(String(localized: "Deleted “\(task.title)”"))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(Surface.ink)
                }
                Button(String(localized: "Undo")) { undo.restore(into: store) }
                    .fontWeight(.bold)
                    .foregroundStyle(Surface.tint)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16)
        }
    }
}
