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

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TaskCardView(task: task, now: context.date,
                         blockedByCount: blockedByCount, blockingCount: blockingCount)
        }
        .onTapGesture { onEdit(task) }
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
        .contextMenu { rowMenu }
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

    @ViewBuilder private var rowMenu: some View {
        Button { onEdit(task) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
        Button { actions.duplicate(task) } label: {
            Label(String(localized: "Duplicate"), systemImage: "plus.square.on.square")
        }
        ShareLink(item: task.shareText) {
            Label(String(localized: "Share"), systemImage: "square.and.arrow.up")
        }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"), systemImage: "checkmark")
        }
        if TimeTracking.runningEntry(task.timeEntries) == nil {
            Button(String(localized: "Start Timer")) { actions.startTimer(task) }
        } else {
            Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
        }
        Menu(String(localized: "Snooze")) {
            ForEach(snoozeMenuPresets.indices, id: \.self) { i in
                Button(snoozeMenuPresets[i].0) { actions.snooze(task, by: snoozeMenuPresets[i].1) }
            }
        }
        Menu(String(localized: "Move to")) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(task, to: q) }
            }
        }
        Button(role: .destructive) { actions.delete(task) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
    }

    /// Six §6.7 snooze presets — intentionally duplicated (not a shared constant), per the Phase-2 decision.
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes), (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour), (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow), (String(localized: "Next week"), .nextWeek)]
    }
}
