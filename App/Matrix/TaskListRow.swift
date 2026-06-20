import SwiftUI
import GSDModel
import GSDStore

/// One task as a `List` row — the shared treatment used by `QuadrantSection` (iPhone
/// matrix) and `FilteredTaskListView` (smart-view results). Live timer via `TimelineView`;
/// blocked/blocking counts injected by the container's `DependencyGraph`.
struct TaskListRow: View {
    let task: Task
    let blockedByCount: Int
    let blockingCount: Int
    let actions: TaskActions
    var onEdit: (Task) -> Void
    @Environment(\.editMode) private var editMode
    @Environment(\.demoClock) private var demoClock

    private var isSelecting: Bool { editMode?.wrappedValue.isEditing == true }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // The demo harness pins `now` so relative due labels are identical on every take;
            // production uses the live TimelineView date and ticks the running timer each second.
            TaskCardView(task: task, now: demoClock ?? context.date,
                         blockedByCount: blockedByCount, blockingCount: blockingCount,
                         onToggle: isSelecting ? nil : { actions.toggle(task) },
                         menu: isSelecting ? nil : { AnyView(TaskRowMenu(task: task, actions: actions, onEdit: onEdit)) })
        }
        // Body tap opens the editor — but only outside multi-select, where a tap must
        // toggle selection instead. `.onTapGesture` (not `.gesture`) lets the disc
        // button and `⋯` menu win hit-testing within their own regions.
        .contentShape(Rectangle())
        .onTapGesture { if !isSelecting { onEdit(task) } }
        .swipeActions(edge: .leading) {
            Button { actions.toggle(task) } label: {
                Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"),
                      systemImage: task.completed ? "arrow.uturn.left" : "checkmark")
            }
            .tint(Surface.success)
        }
        .swipeActions(edge: .trailing) {
            Button(String(localized: "Snooze")) { actions.snooze(task, by: .oneHour) }
                .tint(QuadrantStyle.accent(.notUrgentNotImportant)) // slate
            Button(role: .destructive) { actions.delete(task) } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
            .tint(Surface.alert) // rust
        }
        .contextMenu { TaskRowMenu(task: task, actions: actions, onEdit: onEdit) }
        .accessibilityActions {
            Button(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete")) { actions.toggle(task) }
            Button(String(localized: "Edit")) { onEdit(task) }
            Button(String(localized: "Duplicate")) { actions.duplicate(task) }
            Button(String(localized: "Delete")) { actions.delete(task) }
            Button(String(localized: "Snooze 1 hour")) { actions.snooze(task, by: .oneHour) }
            if TimeTracking.runningEntry(task.timeEntries) == nil {
                Button(String(localized: "Start timer")) { actions.startTimer(task) }
            } else {
                Button(String(localized: "Stop timer")) { actions.stopTimer(task) }
            }
        }
    }
}
