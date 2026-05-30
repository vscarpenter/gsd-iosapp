import SwiftUI
import GSDModel

/// One task row. Phase-1 fields only (subtask progress, dependency badges, due
/// date, timer, snooze arrive in Phase 2). Hosts its own VoiceOver label;
/// custom actions are attached by the enclosing section.
struct TaskCardView: View {
    let task: Task

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(QuadrantStyle.accent(task.quadrant))
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? .secondary : .primary)

                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !task.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(task.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(QuadrantStyle.accent(task.quadrant).opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(task.completed ? QuadrantStyle.accent(task.quadrant) : .secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)                 // ≥44pt hit target (§12.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let state = task.completed ? String(localized: "completed") : String(localized: "active")
        return "\(task.title), \(task.quadrant.title), \(state)"
    }
}
