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

    var body: some View {
        Section {
            if items.isEmpty {
                Button(action: onAdd) {
                    Label(String(localized: "Add to \(quadrant.title)"), systemImage: "plus.circle")
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(items) { task in
                    TaskCardView(task: task)
                        .onTapGesture { onEdit(task) }
                        .swipeActions(edge: .leading) {
                            Button { actions.toggle(task) } label: {
                                Label(task.completed ? "Uncomplete" : "Complete",
                                      systemImage: task.completed ? "arrow.uturn.left" : "checkmark")
                            }
                            .tint(QuadrantStyle.accent(quadrant))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { actions.delete(task) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { rowMenu(task) }
                        .accessibilityActions {
                            Button(task.completed ? "Uncomplete" : "Complete") { actions.toggle(task) }
                            Button("Edit") { onEdit(task) }
                            Button("Delete") { actions.delete(task) }
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
        Button { onEdit(task) } label: { Label("Edit", systemImage: "pencil") }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? "Uncomplete" : "Complete", systemImage: "checkmark")
        }
        Menu(String(localized: "Move to")) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(task, to: q) }
            }
        }
        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
    }
}
