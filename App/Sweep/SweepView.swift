import SwiftUI
import GSDModel
import GSDStore

/// The weekly sweep (D-14, spec-weekly-sweep): one card at a time for what has gone quiet. A pushed
/// screen, opened from the Matrix entry line or Settings. Every action is one that already exists,
/// through `TaskActions`. Opening, skipping, and leaving write nothing to any task. Reaching the end,
/// or tapping Done, stamps "last swept" on this device; leaving another way stamps nothing.
struct SweepView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(\.escalationWindow) private var escalationWindow
    @Environment(\.dismiss) private var dismiss
    @State private var session: SweepSession?
    @State private var failure: TaskActionFailure?
    @State private var dateTarget: Task?
    @AccessibilityFocusState private var titleFocused: Bool

    private var actions: TaskActions {
        TaskActions(store: store, onCompleted: {}, onError: { failure = TaskActionFailure($0) })
    }

    var body: some View {
        Group {
            if let session {
                if let card = session.current, let task = store.tasks.first(where: { $0.id == card.id }) {
                    cardScreen(session: session, card: card, task: task)
                } else if session.isFinished {
                    endScreen
                } else {
                    Color.clear   // settling to the next card
                }
            } else {
                Color.clear
            }
        }
        .background(Surface.paper)
        .navigationTitle(String(localized: "Weekly sweep"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if session?.isFinished == false {
                    Button(String(localized: "Done")) { finish() }
                }
            }
        }
        .taskActionFailureAlert($failure)
        .sheet(item: $dateTarget) { task in
            SweepDateSheet(task: task) { dateTarget = nil }
        }
        .onAppear { openIfNeeded() }
    }

    // MARK: Session

    private var currentCards: [WeeklySweep.Card] {
        WeeklySweep.cards(store.tasks, now: Date(), windowDays: escalationWindow.days, timeZone: .current)
    }

    /// The cards are computed once, when the sweep opens.
    private func openIfNeeded() {
        guard session == nil else { return }
        var opened = SweepSession(cards: currentCards)
        opened.settle(qualifying: Set(opened.cards.map(\.id)))
        session = opened
        announce()
    }

    /// After an action or Skip: go to the next card that still qualifies. Undo doesn't bring a card
    /// back into this session.
    private func next() {
        guard var s = session else { return }
        s.advance()
        s.settle(qualifying: Set(currentCards.map(\.id)))
        session = s
        if s.reachedEnd { stampSwept() }
        announce()
        titleFocused = true
    }

    private func finish() {
        stampSwept()
        dismiss()
    }

    private func stampSwept() { WeeklySweepSettings.stampSwept(at: Date()) }

    private func announce() {
        if let position = session?.position { AccessibilityNotification.Announcement(position).post() }
    }

    // MARK: Card

    private func cardScreen(session: SweepSession, card: WeeklySweep.Card, task: Task) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let position = session.position {
                    Text(position)
                        .font(.callout).monospacedDigit().foregroundStyle(Surface.ink2)
                        .accessibilityLabel(position)
                        .accessibilityAddTraits(.updatesFrequently)   // the live region for "3 of 12"
                }
                SweepCardView(task: task, reason: card.reason, titleFocused: $titleFocused)
                actionButtons(card: card, task: task)
            }
            .padding(20)
        }
        .id(card.id)
    }

    @ViewBuilder
    private func actionButtons(card: WeeklySweep.Card, task: Task) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch card.reason {
            case .overdue:
                complete(task); newDate(task, String(localized: "New date")); markUrgent(task)
                saveForLater(task); delete(task)
            case .escalating:
                markUrgent(task); newDate(task, String(localized: "New date")); complete(task)
            case .stale:
                complete(task); moveTo(task); newDate(task, String(localized: "New date"))
                saveForLater(task); delete(task)
            case .saved:
                returnToMatrix(task); delete(task)
            case .undatedSchedule:
                newDate(task, String(localized: "Add date")); moveTo(task); saveForLater(task)
            }
            action(String(localized: "Skip"), systemImage: "forward") { next() }
        }
    }

    private func action(_ title: String, systemImage: String, role: ButtonRole? = nil,
                        perform: @escaping () -> Void) -> some View {
        Button(role: role, action: perform) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
    }

    private func complete(_ t: Task) -> some View {
        action(String(localized: "Complete"), systemImage: "checkmark.circle") { actions.toggle(t); next() }
    }
    private func newDate(_ t: Task, _ title: String) -> some View {
        action(title, systemImage: "calendar") { dateTarget = t }
    }
    @ViewBuilder private func markUrgent(_ t: Task) -> some View {
        if !t.urgent {
            let target: Escalation.Target = t.important ? .urgentImportant : .urgentNotImportant
            action(String(localized: "Mark urgent"), systemImage: "arrow.up") {
                actions.markUrgent(t, target: target); next()
            }
            .accessibilityHint(target.markUrgentHint)
        }
    }
    private func saveForLater(_ t: Task) -> some View {
        action(String(localized: "Save for later"), systemImage: "bookmark") { actions.moveToSaved(t); next() }
    }
    private func delete(_ t: Task) -> some View {
        action(String(localized: "Delete"), systemImage: "trash", role: .destructive) { actions.delete(t); next() }
    }
    private func returnToMatrix(_ t: Task) -> some View {
        action(String(localized: "Return to matrix"), systemImage: "arrow.uturn.backward") {
            _Concurrency.Task { @MainActor in
                do { try await store.returnToMatrix(id: t.id, quadrant: t.quadrant, dueDate: t.dueDate) }
                catch { failure = TaskActionFailure(String(localized: "Couldn’t return that task: \(error.localizedDescription)")) }
            }
            next()
        }
    }
    private func moveTo(_ t: Task) -> some View {
        Menu {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(t, to: q); next() }
            }
        } label: {
            Label(String(localized: "Move to quadrant"), systemImage: "square.grid.2x2")
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 44)
        }
    }

    // MARK: End

    private var freeSlot: Bool {
        TopThree.nextRank(store.tasks, now: Date(), timeZone: .current) != nil
    }

    private var endScreen: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("That’s the sweep.")
                .font(.serif(.title2).weight(.semibold))
                .foregroundStyle(Surface.ink)
                .accessibilityAddTraits(.isHeader)
            if SweepSession.offersTopThree(freeSlot: freeSlot, topThreeShipped: true) {
                Button(String(localized: "Pick today’s top three")) {
                    palette.compactTab = 0
                    palette.regularSelection = .matrix
                    palette.todaySuggestionsRequest += 1
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Surface.tint)
            }
            Button(String(localized: "Back to the matrix")) { dismiss() }
                .buttonStyle(.borderless)
                .frame(minHeight: 44)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }
}

/// The card: the task's title, due chip, and quadrant, and one reason line. Facts only: it never
/// says behind, neglected, still, missed, or forgot.
private struct SweepCardView: View {
    let task: Task
    let reason: WeeklySweep.Reason
    var titleFocused: AccessibilityFocusState<Bool>.Binding

    private var reasonLine: String {
        switch reason {
        case .overdue: String(localized: "Due date passed")
        case .escalating: String(localized: "Due soon, not marked urgent")
        case .stale: String(localized: "No changes in 14 days or more")
        case .saved: String(localized: "Saved over a month ago")
        case .undatedSchedule: String(localized: "No date yet")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.serif(.title2).weight(.semibold))
                .foregroundStyle(Surface.ink)
                .accessibilityFocused(titleFocused)
            HStack(spacing: 8) {
                Image(systemName: QuadrantStyle.symbol(task.quadrant)).accessibilityHidden(true)
                Text(task.quadrant.title)
                if let due = task.dueDate {
                    Text("·").accessibilityHidden(true)
                    Text(RelativeDate.dueString(for: due))
                }
            }
            .font(.callout)
            .foregroundStyle(QuadrantStyle.accent(task.quadrant))
            Text(reasonLine).font(.callout).foregroundStyle(Surface.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Surface.surface))
    }
}

/// New date and Add date: a day picker that saves through the same merge the editor uses. A date
/// with no time of day is an all-day due date.
private struct SweepDateSheet: View {
    @Environment(TaskStore.self) private var store
    let task: Task
    var onClose: () -> Void
    @State private var date: Date
    @State private var error: String?

    init(task: Task, onClose: @escaping () -> Void) {
        self.task = task
        self.onClose = onClose
        _date = State(initialValue: Calendar.current.startOfDay(for: max(task.dueDate ?? Date(), Date())))
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(String(localized: "Due"), selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                if let error { Text(error).foregroundStyle(Surface.alert) }
            }
            .navigationTitle(task.dueDate == nil ? String(localized: "Add date") : String(localized: "New date"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(String(localized: "Cancel"), action: onClose) }
                ToolbarItem(placement: .confirmationAction) { Button(String(localized: "Save"), action: save) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save() {
        _Concurrency.Task { @MainActor in
            do {
                let original = EditorMerge.untouched(task)
                var edited = original
                edited.dueDate = Calendar.current.startOfDay(for: date)
                _ = try await store.saveEdits(edited, openedAs: original)
                onClose()
            } catch {
                self.error = String(localized: "Couldn’t save that date: \(error.localizedDescription)")
            }
        }
    }
}
