import SwiftUI
import GSDModel

/// One task row. Hosts its own VoiceOver label; custom actions are attached
/// by the enclosing section. Visual anatomy follows the editorial design
/// language: a 3pt accent spine, SF headline title, footnote meta, and a
/// 28pt completion disc that fills with the quadrant accent when done.
struct TaskCardView: View {
    let task: Task

    /// Injected for the live-ticking timer + deterministic previews.
    var now: Date = .now
    /// Counts for dependency badges, supplied by the enclosing section from the
    /// live graph (keeps the card store-free). Defaults to no badges.
    var blockedByCount: Int = 0
    var blockingCount: Int = 0

    /// When non-nil, the completion disc becomes a tappable button (parity with the
    /// web's complete circle). Nil keeps the disc decorative (previews/non-interactive hosts).
    var onToggle: (() -> Void)?
    /// When non-nil, a trailing `⋯` button presents this menu content.
    var menu: (() -> AnyView)?

    private var isBlocked: Bool { blockedByCount > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(QuadrantStyle.accent(task.quadrant))
                .frame(width: 3)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? Surface.ink3 : Surface.ink)

                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.subheadline)
                        .foregroundStyle(task.completed ? Surface.ink3 : descriptionColor)
                        .lineLimit(2)
                }

                if !task.tags.isEmpty { tagRow }

                // --- Phase 2 indicators ---
                if hasMetadata { metadataRow }
                if !task.subtasks.isEmpty { subtaskProgress }
            }

            Spacer(minLength: 0)

            trailingControls
        }
        .opacity(isBlocked && !task.completed ? 0.62 : 1)
        .padding(.vertical, 12)               // in-card vertical air (4-pt grid)
        .frame(minHeight: 44)                 // ≥44pt hit target (§12.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        // Stable handle for the demo-video XCUITest (and a useful UI-test anchor generally).
        // `.combine` above merges the disc into this element, so the card is addressed as a whole.
        .accessibilityIdentifier("task-card-\(task.id)")
    }

    /// A captured link surfaces its URL as the description — render it quietly.
    private var descriptionColor: Color {
        let d = task.description
        return (d.hasPrefix("http://") || d.hasPrefix("https://")) ? Surface.ink3 : Surface.ink2
    }

    /// Trailing cluster: the optional `⋯` overflow menu and the completion control.
    /// Both collapse to nothing when their callback is absent (decorative previews).
    @ViewBuilder private var trailingControls: some View {
        HStack(spacing: 10) {
            if let menu {
                Menu { menu() } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Surface.ink3)
                        .frame(width: 30, height: 30)          // glyph target; row's 44pt height supplies the rest
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "More actions"))
            }
            completionControl
        }
    }

    @ViewBuilder private var completionControl: some View {
        if let onToggle {
            // A nested Button wins hit-testing on iOS, but on Mac Catalyst the enclosing
            // row's `.onTapGesture` (tap-to-edit) swallows it, opening the editor instead of
            // toggling the disc. A high-priority tap outranks that ancestor gesture on both
            // platforms, so the disc reliably completes the task everywhere (parity with web).
            completionDisc
                .frame(width: 44, height: 44)                  // ≥44pt hit target around the 28pt disc (§12.3)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded { onToggle() })
                .accessibilityLabel(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"))
        } else {
            completionDisc.accessibilityHidden(true)
        }
    }

    private var completionDisc: some View {
        ZStack {
            if task.completed {
                Circle().fill(QuadrantStyle.accent(task.quadrant))
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Surface.inkOnAccent)
            } else {
                Circle().stroke(Surface.hairlineStrong, lineWidth: 2)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var tagRow: some View {
        HStack(spacing: 6) {
            ForEach(task.tags, id: \.self) { tag in
                Text("#\(tag)")
                    .font(.footnote)
                    .foregroundStyle(QuadrantStyle.accent(task.quadrant))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(QuadrantStyle.wash(task.quadrant), in: Capsule())
            }
        }
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
                let state = RelativeDate.state(for: dueDate, reference: now)
                Label(RelativeDate.dueString(for: dueDate, reference: now),
                      systemImage: state == .overdue ? "exclamationmark.triangle" : "calendar")
                    .foregroundStyle(dueColor(for: dueDate))
                    .fontWeight(state == .upcoming ? .regular : .semibold)
            }
            if task.recurrence != .none {
                Image(systemName: "repeat").accessibilityLabel(String(localized: "Repeats"))
            }
            if blockedByCount > 0 {
                Label(String(localized: "Blocked by \(blockedByCount)"), systemImage: "lock")
            }
            if blockingCount > 0 {
                Label("\(blockingCount)", systemImage: "arrow.right.circle")
                    .accessibilityLabel(String(localized: "Blocking \(blockingCount)"))
            }
            if let runningStart {
                runningTimer(since: runningStart)
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
        .font(.footnote)
        .foregroundStyle(Surface.ink3)
        .lineLimit(1)
    }

    /// Live elapsed since the running entry started: pulsing accent dot + tabular HH:MM:SS.
    private func runningTimer(since start: Date) -> some View {
        let elapsed = Int(now.timeIntervalSince(start))
        return HStack(spacing: 6) {
            PulsingDot(color: QuadrantStyle.accent(task.quadrant))
            Text(Self.hms(elapsed)).monospacedDigit()
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(QuadrantStyle.accent(task.quadrant))
        .accessibilityLabel(String(localized: "timer running \(TimeTracking.format(minutes: elapsed / 60))"))
    }

    static func hms(_ seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    @ViewBuilder private var subtaskProgress: some View {
        let done = task.subtasks.filter(\.completed).count
        let total = task.subtasks.count
        let fraction = total > 0 ? Double(done) / Double(total) : 0
        let complete = done == total
        let fill = complete ? Surface.success : QuadrantStyle.accent(task.quadrant)
        HStack(spacing: 9) {
            Capsule().fill(Surface.sunken)
                .frame(width: 84, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(fill).frame(width: 84 * fraction, height: 6)
                }
            Text("\(done)/\(total)")
                .font(.footnote).monospacedDigit()
                .fontWeight(complete ? .semibold : .regular)
                .foregroundStyle(complete ? Surface.success : Surface.ink2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(done) of \(total) subtasks done"))
    }

    private func dueColor(for dueDate: Date) -> Color {
        switch RelativeDate.state(for: dueDate, reference: now) {
        case .overdue:  return Surface.alert
        case .today:    return QuadrantStyle.accent(.notUrgentImportant) // tide
        case .upcoming: return Surface.ink3
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

/// A small accent dot that breathes. Its own identity keeps the repeating
/// animation smooth even when the parent card re-renders each second for the
/// live timer. Suppressed under Reduce Motion.
private struct PulsingDot: View {
    let color: Color
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
            .accessibilityHidden(true)
    }
}
