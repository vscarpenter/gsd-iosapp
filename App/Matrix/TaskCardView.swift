import SwiftUI
import GSDModel

/// One task row. Hosts its own VoiceOver label; custom actions are attached
/// by the enclosing section.
struct TaskCardView: View {
    let task: Task

    /// Injected for the live-ticking timer + deterministic previews.
    var now: Date = .now
    /// Counts for dependency badges, supplied by the enclosing section from the
    /// live graph (keeps the card store-free). Defaults to no badges.
    var blockedByCount: Int = 0
    var blockingCount: Int = 0

    private var isBlocked: Bool { blockedByCount > 0 }

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

                // --- Phase 2 indicators ---
                if hasMetadata { metadataRow }
                if !task.subtasks.isEmpty { subtaskProgress }
            }

            Spacer(minLength: 0)

            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(task.completed ? QuadrantStyle.accent(task.quadrant) : .secondary)
                .accessibilityHidden(true)
        }
        .opacity(isBlocked && !task.completed ? 0.55 : 1)
        .padding(.vertical, 8)
        .frame(minHeight: 44)                 // ≥44pt hit target (§12.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var hasMetadata: Bool {
        task.dueDate != nil || task.recurrence != .none
            || blockedByCount > 0 || blockingCount > 0
            || TimeTracking.runningEntry(task.timeEntries) != nil
            || (task.timeSpent ?? 0) > 0
            || (task.snoozedUntil.map { $0 > now } ?? false)
    }

    @ViewBuilder private var metadataRow: some View {
        let runningStart = TimeTracking.runningEntry(task.timeEntries)?.startedAt
        HStack(spacing: 10) {
            if let dueDate = task.dueDate {
                Label(RelativeDate.dueString(for: dueDate, reference: now),
                      systemImage: "calendar")
                    .foregroundStyle(dueColor(for: dueDate))
            }
            if task.recurrence != .none {
                Image(systemName: "repeat").accessibilityLabel(String(localized: "Repeats"))
            }
            if blockedByCount > 0 {
                Label("\(blockedByCount)", systemImage: "lock")
                    .accessibilityLabel(String(localized: "Blocked by \(blockedByCount)"))
            }
            if blockingCount > 0 {
                Label("\(blockingCount)", systemImage: "arrow.right.circle")
                    .accessibilityLabel(String(localized: "Blocking \(blockingCount)"))
            }
            if let runningStart {
                // Live elapsed since the running entry started.
                let elapsedMinutes = Int(now.timeIntervalSince(runningStart) / 60.0)
                Label(TimeTracking.format(minutes: elapsedMinutes), systemImage: "stopwatch")
                    .foregroundStyle(.green)
            } else if let timeSpent = task.timeSpent, timeSpent > 0 {
                Label(TimeTracking.format(minutes: timeSpent), systemImage: "clock")
            }
            if let snoozedUntil = task.snoozedUntil, snoozedUntil > now {
                // Time-granular remaining (A10) — NOT dueString, which would floor to
                // the day and render "Due today" for the short presets.
                Label(RelativeDate.remainingString(until: snoozedUntil, reference: now),
                      systemImage: "moon.zzz")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var subtaskProgress: some View {
        let done = task.subtasks.filter(\.completed).count
        let total = task.subtasks.count
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: Double(done), total: Double(total))
                .tint(QuadrantStyle.accent(task.quadrant))
            Text("\(done)/\(total)").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(done) of \(total) subtasks done"))
    }

    private func dueColor(for dueDate: Date) -> Color {
        switch RelativeDate.state(for: dueDate, reference: now) {
        case .overdue:  return .red
        case .today:    return .orange
        case .upcoming: return .secondary
        }
    }

    private var accessibilityLabel: String {
        let state = task.completed ? String(localized: "completed") : String(localized: "active")
        var parts = ["\(task.title)", task.quadrant.title, state]
        if let dueDate = task.dueDate { parts.append(RelativeDate.dueString(for: dueDate, reference: now)) }
        if task.recurrence != .none { parts.append(String(localized: "repeats")) }
        if isBlocked { parts.append(String(localized: "blocked by \(blockedByCount)")) }
        if blockingCount > 0 { parts.append(String(localized: "blocking \(blockingCount)")) }
        if !task.subtasks.isEmpty {
            let done = task.subtasks.filter(\.completed).count
            parts.append(String(localized: "\(done) of \(task.subtasks.count) subtasks done"))
        }
        if let runningStart = TimeTracking.runningEntry(task.timeEntries)?.startedAt {
            let elapsed = Int(now.timeIntervalSince(runningStart) / 60.0)
            parts.append(String(localized: "timer running \(TimeTracking.format(minutes: elapsed))"))
        } else if let timeSpent = task.timeSpent, timeSpent > 0 {
            parts.append(String(localized: "tracked \(TimeTracking.format(minutes: timeSpent))"))
        }
        if let snoozedUntil = task.snoozedUntil, snoozedUntil > now {
            parts.append(String(localized: "snoozed \(RelativeDate.remainingString(until: snoozedUntil, reference: now))"))
        }
        return parts.joined(separator: ", ")
    }
}
