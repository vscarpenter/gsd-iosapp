import SwiftUI
import GSDModel
import GSDStore

struct QuadrantCell: View {
    @Environment(TaskStore.self) private var store
    let quadrant: Quadrant
    let showCompleted: Bool
    let actions: TaskActions
    @Binding var selection: Set<String>
    let isSelecting: Bool
    var onEdit: (Task) -> Void
    var onAdd: () -> Void

    @State private var isTargeted = false
    /// Which row is swiped open — shared with every row so opening one closes the others.
    @State private var openTaskID: String?
    private var items: [Task] { store.tasks(in: quadrant, showCompleted: showCompleted) }
    private var activeCount: Int { store.tasks(in: quadrant, showCompleted: false).count }
    /// Computed once per render from the full task snapshot; dependencies cross quadrants.
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: QuadrantStyle.symbol(quadrant))
                    .font(.title3).foregroundStyle(QuadrantStyle.accent(quadrant))
                Text(quadrant.title)
                    .font(.serif(.title3).weight(.semibold))
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Spacer()
                Text("\(activeCount)").font(.callout).monospacedDigit()
                    .foregroundStyle(Surface.ink3)
                    .accessibilityLabel(String(localized: "\(activeCount) active"))
            }
            if items.isEmpty {
                QuadrantEmptyPrompt(quadrant: quadrant, action: onAdd)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
                cardRow(task)
                if index < items.count - 1 {
                    Rectangle().fill(Surface.hairline).frame(height: 1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(isTargeted ? QuadrantStyle.wash(quadrant) : Surface.surface,
                    in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(isTargeted ? QuadrantStyle.accent(quadrant) : Surface.hairline,
                              lineWidth: isTargeted ? 2 : 1)
        )
        .shadow(color: Surface.shadow.opacity(0.10), radius: 10, x: 0, y: 4)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let task = store.tasks.first(where: { $0.id == id }) else { return false }
            actions.move(task, to: quadrant)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder private func cardRow(_ task: Task) -> some View {
        if isSelecting {
            Button {
                toggleSelection(task.id)
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: selection.contains(task.id) ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(selection.contains(task.id) ? Surface.tint : Surface.ink3)
                        .frame(width: 28)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        TaskCardView(
                            task: task,
                            now: context.date,
                            blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                            blockingCount: graph.blockedTasks(of: task.id).count
                        )
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(task.id) ? .isSelected : [])
        } else {
            swipeRow(task)
        }
    }

    private func swipeRow(_ task: Task) -> some View {
        SwipeRevealRow(
            task: task,
            actions: actions,
            onEdit: onEdit,
            openTaskID: $openTaskID,
            menu: { TaskRowMenu(task: task, actions: actions, onEdit: onEdit) },
            content: {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    TaskCardView(
                        task: task,
                        now: context.date,
                        blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                        blockingCount: graph.blockedTasks(of: task.id).count,
                        onToggle: { actions.toggle(task) },
                        menu: { AnyView(TaskRowMenu(task: task, actions: actions, onEdit: onEdit)) }
                    )
                }
            }
        )
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

    private func toggleSelection(_ id: String) {
        if selection.contains(id) { selection.remove(id) }
        else { selection.insert(id) }
    }
}
