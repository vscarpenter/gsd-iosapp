import SwiftUI
import GSDModel
import GSDStore

/// "Today": up to three picks above the matrix (D-13, spec-top-three section 4). It suggests and
/// offers but never picks, and it writes only when the user taps. A pick counts only on its own
/// date, so the section re-reads the clock at local midnight and when the app returns.
///
/// Copy is fixed across web, Android, and Apple: "Today", "Pick up to three for today",
/// "From yesterday", "Two devices picked for today. Tidy up?". It never says missed,
/// unfinished, or failed, and shows no progress meter.
struct TopThreeSection: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.escalationWindow) private var escalationWindow
    @Environment(\.scenePhase) private var scenePhase
    @Environment(PaletteController.self) private var palette
    @State private var now = Date()
    @State private var showingSuggestions = false
    @State private var tidyDismissed = false

    let actions: TaskActions
    var onEdit: (Task) -> Void

    private var zone: TimeZone { .current }
    private var picks: TopThree.Picks { TopThree.todaysPicks(store.tasks, now: now, timeZone: zone) }
    private var today: String { TopThree.localDate(now, timeZone: zone) }

    private var pickedTasks: [Task] {
        picks.picks.compactMap { id in store.tasks.first { $0.id == id } }
    }

    private var carryOver: (label: String, tasks: [Task])? {
        guard hasFreeSlot else { return nil }
        let offer = TopThree.carryOver(store.tasks, now: now, timeZone: zone)
        guard let from = offer.fromDate else { return nil }
        let tasks = offer.ids.compactMap { id in store.tasks.first { $0.id == id } }
        return tasks.isEmpty ? nil : (TopThree.carryOverLabel(from: from, today: today, timeZone: zone), tasks)
    }

    private var suggestions: [Task] {
        let carried = Set(carryOver?.tasks.map(\.id) ?? [])
        return TopThree.suggest(store.tasks, now: now, windowDays: escalationWindow.days, timeZone: zone)
            .filter { !carried.contains($0) }
            .prefix(TopThree.maxPicks)
            .compactMap { id in store.tasks.first { $0.id == id } }
    }

    /// Free means `nextRank` isn't nil, not "fewer than three picks": ranks 1, 1, and 2 leave rank 3 free.
    private var hasFreeSlot: Bool { TopThree.nextRank(store.tasks, now: now, timeZone: zone) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(Array(pickedTasks.enumerated()), id: \.element.id) { index, task in
                TaskCardView(task: task, now: now,
                             accessibilityPosition: Self.ordinal(index),
                             onToggle: { actions.toggle(task) },
                             menu: { AnyView(TaskRowMenu(task: task, actions: actions, onEdit: onEdit)) })
                    .contentShape(Rectangle())
                    .onTapGesture { onEdit(task) }
                    .contextMenu { TaskRowMenu(task: task, actions: actions, onEdit: onEdit) }
            }
            if picks.needsTidy && !tidyDismissed { tidyOffer }
            if let carryOver {
                offerGroup(title: carryOver.label, tasks: carryOver.tasks)
            }
            if hasFreeSlot { pickLine }
            if hasFreeSlot && showingSuggestions { suggestionsGroup }
        }
        .padding(.vertical, 4)
        .task(id: today) { await sleepUntilMidnight() }
        .onChange(of: palette.todaySuggestionsRequest) { _, _ in withAnimation { showingSuggestions = true } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { now = Date() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            now = Date()
        }
    }

    // MARK: Pieces

    private var header: some View {
        Text("Today")
            .font(.serif(.title3).weight(.semibold))
            .foregroundStyle(Surface.ink)
            .accessibilityAddTraits(.isHeader)
            .accessibilityLabel(String(localized: "Today, \(picks.picks.count) of 3"))
    }

    /// With no picks this is the whole section: one quiet line that opens the suggestions.
    private var pickLine: some View {
        Button { withAnimation { showingSuggestions.toggle() } } label: {
            Text("Pick up to three for today")
                .font(.callout)
                .foregroundStyle(Surface.ink2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(Surface.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [5])))
        }
        .buttonStyle(.plain)
        .accessibilityHint(showingSuggestions
                           ? String(localized: "Hides the suggestions")
                           : String(localized: "Shows suggestions"))
    }

    private var suggestionsGroup: some View {
        Group {
            if suggestions.isEmpty {
                Text("Nothing to suggest right now.")
                    .font(.footnote).foregroundStyle(Surface.ink2)
            } else {
                offerGroup(title: nil, tasks: suggestions)
            }
        }
    }

    private func offerGroup(title: String?, tasks: [Task]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Surface.ink2)
            }
            ForEach(tasks) { task in
                HStack(spacing: 12) {
                    Text(task.title).font(.callout).foregroundStyle(Surface.ink).lineLimit(2)
                    Spacer(minLength: 8)
                    Button { actions.addToToday(task) } label: {
                        Text("Add to today")
                            .font(.callout.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)   // the audit measures the label, not the button
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(String(localized: "Add to today: \(task.title)"))
                }
            }
        }
    }

    private var tidyOffer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Two devices picked for today. Tidy up?")
                .font(.callout).foregroundStyle(Surface.ink)
            HStack(spacing: 16) {
                Button(String(localized: "Tidy")) { actions.tidyToday() }
                    .font(.callout.weight(.semibold))
                Button(String(localized: "Not now")) { tidyDismissed = true }
                    .font(.callout)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Surface.surface))
    }

    // MARK: Clock

    /// Sleeps to the next local midnight, then re-reads the date so yesterday's picks stop counting.
    private func sleepUntilMidnight() async {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        guard let midnight = calendar.nextDate(after: Date(), matching: DateComponents(hour: 0, minute: 0, second: 1),
                                               matchingPolicy: .nextTime) else { return }
        try? await _Concurrency.Task.sleep(for: .seconds(max(1, midnight.timeIntervalSinceNow)))
        guard !_Concurrency.Task.isCancelled else { return }
        now = Date()
    }

    // MARK: Words

    static func ordinal(_ index: Int) -> String {
        switch index {
        case 0: String(localized: "first")
        case 1: String(localized: "second")
        default: String(localized: "third")
        }
    }
}
