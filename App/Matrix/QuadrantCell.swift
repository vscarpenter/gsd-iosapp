import SwiftUI
import GSDModel
import GSDStore

struct QuadrantCell: View {
    @Environment(TaskStore.self) private var store
    let quadrant: Quadrant
    let showCompleted: Bool
    let actions: TaskActions
    var onEdit: (Task) -> Void
    var onAdd: () -> Void

    @State private var isTargeted = false
    private var items: [Task] { store.tasks(in: quadrant, showCompleted: showCompleted) }
    private var activeCount: Int { store.tasks(in: quadrant, showCompleted: false).count }
    /// Computed once per render from the full task snapshot; dependencies cross quadrants.
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(quadrant.title, systemImage: QuadrantStyle.symbol(quadrant))
                    .font(.serif(.headline))
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Spacer()
                Text("\(activeCount)").font(.caption).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Button(action: onAdd) {
                    Label(String(localized: "Add to \(quadrant.title)"), systemImage: "plus.circle")
                }
                .foregroundStyle(.secondary).padding(.vertical, 4)
            }
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
                .draggable(task.id)
                .contextMenu { cellMenu(task) }
                .accessibilityActions {
                    Button(task.completed ? "Uncomplete" : "Complete") { actions.toggle(task) }
                    Button("Edit") { onEdit(task) }
                    Button("Delete") { actions.delete(task) }
                    Button(String(localized: "Snooze 1 hour")) { actions.snooze(task, by: .oneHour) }
                    if TimeTracking.runningEntry(task.timeEntries) == nil {
                        Button(String(localized: "Start timer")) { actions.startTimer(task) }
                    } else {
                        Button(String(localized: "Stop timer")) { actions.stopTimer(task) }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(QuadrantStyle.accent(quadrant).opacity(isTargeted ? 0.12 : 0.04),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(QuadrantStyle.accent(quadrant).opacity(0.3)))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let task = store.tasks.first(where: { $0.id == id }) else { return false }
            actions.move(task, to: quadrant)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder private func cellMenu(_ task: Task) -> some View {
        Button { onEdit(task) } label: { Label("Edit", systemImage: "pencil") }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? "Uncomplete" : "Complete", systemImage: "checkmark")
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
        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
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
