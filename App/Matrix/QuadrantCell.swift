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
                TaskCardView(task: task)
                    .onTapGesture { onEdit(task) }
                    .draggable(task.id)
                    .contextMenu {
                        Button { onEdit(task) } label: { Label("Edit", systemImage: "pencil") }
                        Button { actions.toggle(task) } label: {
                            Label(task.completed ? "Uncomplete" : "Complete", systemImage: "checkmark")
                        }
                        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .accessibilityActions {
                        Button(task.completed ? "Uncomplete" : "Complete") { actions.toggle(task) }
                        Button("Edit") { onEdit(task) }
                        Button("Delete") { actions.delete(task) }
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
}
