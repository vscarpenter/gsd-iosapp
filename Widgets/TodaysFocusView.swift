import SwiftUI
import WidgetKit
import GSDSnapshot

struct TodaysFocusView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: TodaysFocusEntry

    private var visibleCount: Int { family == .systemSmall ? 3 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "Today's Focus"), systemImage: "target")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if entry.snapshot.tasks.isEmpty {
                Spacer(minLength: 0)
                Text(String(localized: "All clear"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.snapshot.tasks.prefix(visibleCount)) { task in
                    Link(destination: DeepLinkRoute.task(task.id).url) {
                        row(task)
                    }
                }
                if entry.snapshot.totalCount > visibleCount {
                    Text(String(localized: "+\(entry.snapshot.totalCount - visibleCount) more"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLinkRoute.smartView("today-focus").url)
    }

    /// Every row is a Do First task, so the marker carries the due state, not the quadrant:
    /// filled for overdue, half for due today, outline for later or no date. Shape and weight
    /// do the work because the tinted and clear Home Screen modes collapse every color to one
    /// accent; in full color the marker takes the widget tint and the accented mode tints it.
    private func row(_ task: WidgetTask) -> some View {
        let state = dueState(task)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: state.symbol)
                .font(.caption2)
                .foregroundStyle(renderingMode == .fullColor ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .widgetAccentable()
            Text(task.title)
                .font(.caption)
                .fontWeight(state == .overdue ? .semibold : .regular)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.spoken.map { "\(task.title), \($0)" } ?? task.title)
    }

    private enum DueState {
        case overdue, today, later

        var symbol: String {
            switch self {
            case .overdue: "circle.fill"
            case .today: "circle.lefthalf.filled"
            case .later: "circle"
            }
        }

        var spoken: String? {
            switch self {
            case .overdue: String(localized: "overdue")
            case .today: String(localized: "due today")
            case .later: nil
            }
        }
    }

    private func dueState(_ task: WidgetTask) -> DueState {
        guard let due = task.dueDate else { return .later }
        let calendar = Calendar.current
        if calendar.isDate(due, inSameDayAs: entry.date) { return .today }
        return due < calendar.startOfDay(for: entry.date) ? .overdue : .later
    }
}
