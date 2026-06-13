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
                QuadrantEmptyPrompt(quadrant: quadrant, action: onAdd)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            } else {
                ForEach(items) { task in
                    TaskListRow(
                        task: task,
                        blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                        blockingCount: graph.blockedTasks(of: task.id).count,
                        actions: actions,
                        onEdit: onEdit
                    )
                    .tag(task.id)
                    .listRowBackground(Surface.surface)
                    .listRowSeparatorTint(Surface.hairline)
                }
            }
        } header: {
            HStack(spacing: 8) {
                Image(systemName: QuadrantStyle.symbol(quadrant))
                    .font(.title3)
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Text(quadrant.title)
                    .font(.serif(.title3).weight(.semibold))
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Spacer()
                Text("\(activeCount)")
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(Surface.ink3)
                    .accessibilityLabel(String(localized: "\(activeCount) active"))
            }
            .textCase(nil) // keep the serif title cased, not the default uppercased label
            .padding(.bottom, 2)
            .id(quadrant)   // ScrollViewReader anchor for ⌘1–⌘4 quadrant focus
        }
    }
}

/// A quiet dashed prompt shown in place of a quadrant's task group when it is
/// empty (inside an otherwise-populated matrix) — not a full-screen takeover.
/// Shared by the iPhone `QuadrantSection` and the iPad `QuadrantCell`.
struct QuadrantEmptyPrompt: View {
    let quadrant: Quadrant
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(Surface.ink3, lineWidth: 1.5)
                    Image(systemName: "plus").font(.footnote.weight(.semibold))
                        .foregroundStyle(Surface.ink3)
                }
                .frame(width: 26, height: 26)

                Text("\(Text(headline).foregroundStyle(Surface.ink3))  \(Text(String(localized: "Add to \(quadrant.title)")).foregroundStyle(Surface.ink2))")
                    .font(.callout)

                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Surface.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "\(headline) Add to \(quadrant.title)"))
    }

    private var headline: String {
        switch quadrant {
        case .urgentImportant:       String(localized: "No fires right now.")
        case .notUrgentImportant:    String(localized: "Nothing scheduled yet.")
        case .urgentNotImportant:    String(localized: "Nothing to hand off.")
        case .notUrgentNotImportant: String(localized: "Nothing to drop.")
        }
    }
}
