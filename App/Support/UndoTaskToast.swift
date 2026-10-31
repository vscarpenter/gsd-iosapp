import SwiftUI
import GSDModel
import GSDStore

extension Notification.Name {
    /// Posted by `TaskActions.delete` after the store commits, carrying the deleted `Task`
    /// snapshot as the notification object so the root undo window can offer restore.
    static let gsdTaskDeleted = Notification.Name("dev.vinny.gsd.taskDeleted")
    static let gsdTaskSaved = Notification.Name("dev.vinny.gsd.taskSaved")
    /// Posted by `TaskActions.markUrgent`, carrying the task as it was BEFORE the move.
    static let gsdTaskMarkedUrgent = Notification.Name("dev.vinny.gsd.taskMarkedUrgent")
}

enum UndoTaskAction {
    case deleted(Task)
    case saved(Task)
    /// Carries the task as it was before Mark urgent, so Undo can move it back.
    case markedUrgent(Task)

    var task: Task { switch self { case .deleted(let task), .saved(let task), .markedUrgent(let task): task } }
    var message: String {
        switch self {
        case .deleted(let task): String(localized: "Deleted “\(task.title)”")
        case .saved(let task): String(localized: "Moved “\(task.title)” to Saved")
        case .markedUrgent(let task):
            String(localized: "Marked “\(task.title)” urgent. Moved to \(Quadrant(urgent: true, important: task.important).title)")
        }
    }
}

/// One recovery window across surfaces. Deleted items restore from trash; a move to Saved
/// can be undone only while the saved transition is unchanged, including by another device.
@MainActor @Observable
final class UndoTaskController {
    private(set) var action: UndoTaskAction?
    var failure: TaskActionFailure?
    private var expiry: _Concurrency.Task<Void, Never>?

    /// Opens the window for `task` and schedules its close.
    func noteDeleted(_ task: Task) {
        note(.deleted(task))
    }

    func noteSaved(_ task: Task) {
        note(.saved(task))
    }

    func noteMarkedUrgent(_ before: Task) {
        note(.markedUrgent(before))
    }

    private func note(_ next: UndoTaskAction) {
        withAnimation { action = next }
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "\(next.message). Undo is available."))
        expiry?.cancel()
        expiry = _Concurrency.Task { [weak self] in
            // VoiceOver users navigate slower than sighted users tap: hold longer.
            let seconds: Double = UIAccessibility.isVoiceOverRunning ? 12 : 6
            try? await _Concurrency.Task.sleep(for: .seconds(seconds))
            guard !_Concurrency.Task.isCancelled, let self, self.action?.task.id == next.task.id else { return }
            withAnimation { self.action = nil }
        }
    }

    func restore(into store: TaskStore) {
        guard let action else { return }
        withAnimation { self.action = nil }
        _Concurrency.Task { @MainActor in
            do {
                switch action {
                case .deleted(let task): try await store.restoreFromTrash(id: task.id)
                case .saved(let task): try await store.undoMoveToSaved(task)
                case .markedUrgent(let before): try await store.move(before, to: before.quadrant)
                }
            } catch {
                failure = TaskActionFailure(String(localized: "Couldn’t undo that action: \(error.localizedDescription)"))
            }
        }
    }
}

/// The ink capsule for the regular root (iPad, Mac), overlaid above the bottom edge.
struct UndoTaskToast: View {
    let undo: UndoTaskController
    @Environment(TaskStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let action = undo.action {
            HStack(spacing: 14) {
                Text(action.message)
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
struct UndoTaskAccessory: View {
    let undo: UndoTaskController
    @Environment(TaskStore.self) private var store
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let action = undo.action {
            HStack(spacing: 12) {
                if placement != .inline {
                    Text(action.message)
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
