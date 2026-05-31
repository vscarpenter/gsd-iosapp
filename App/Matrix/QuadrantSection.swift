import SwiftUI
import GSDModel
import GSDStore

/// One quadrant as a `List` `Section` (iPhone) — enables native swipe actions.
struct QuadrantSection: View {
    @Environment(TaskStore.self) private var store
    let quadrant: Quadrant
    let showCompleted: Bool
    let actions: TaskActions
    var onEdit: (Task) -> Void
    var onAdd: () -> Void

    private var items: [Task] { store.tasks(in: quadrant, showCompleted: showCompleted) }
    private var activeCount: Int { store.tasks(in: quadrant, showCompleted: false).count }
    /// Computed once per render from the full task snapshot; dependencies cross quadrants.
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    var body: some View {
        Section {
            if items.isEmpty {
                Button(action: onAdd) {
                    Label(String(localized: "Add to \(quadrant.title)"), systemImage: "plus.circle")
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(items) { task in
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        TaskCardView(
                            task: task,
                            now: context.date,
                            blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                            blockingCount: graph.blockedTasks(of: task.id).count
                        )
                    }
                    .onTapGesture { onEdit(task) }
                    .swipeActions(edge: .leading) {
                        Button { actions.toggle(task) } label: {
                            Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"),
                                  systemImage: task.completed ? "arrow.uturn.left" : "checkmark")
                        }
                        .tint(QuadrantStyle.accent(quadrant))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(String(localized: "Snooze")) { actions.snooze(task, by: .oneHour) }
                            .tint(.indigo)
                        Button(role: .destructive) { actions.delete(task) } label: {
                            Label(String(localized: "Delete"), systemImage: "trash")
                        }
                    }
                    .contextMenu { rowMenu(task) }
                    .accessibilityActions {
                        Button(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete")) { actions.toggle(task) }
                        Button(String(localized: "Edit")) { onEdit(task) }
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
        } header: {
            HStack {
                Label(quadrant.title, systemImage: QuadrantStyle.symbol(quadrant))
                    .font(.serif(.headline))
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Spacer()
                Text("\(activeCount)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "\(activeCount) active"))
            }
        }
    }

    @ViewBuilder private func rowMenu(_ task: Task) -> some View {
        Button { onEdit(task) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
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

    /// Six §6.7 snooze presets. Intentionally NOT extracted to a shared constant
    /// (duplicated in the editor per plan decision).
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes),
         (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour),
         (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow),
         (String(localized: "Next week"), .nextWeek)]
    }
}
