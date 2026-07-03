import SwiftUI
import UIKit
import GSDModel
import GSDStore

struct TaskEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// iPhone-only: which detent the sheet is at. Drives the "Show all details"
    /// affordance — 10 of the editor's 12 sections live below the medium fold.
    @State private var detent: PresentationDetent = .medium
    /// Scoped replacement for the old toolbar `EditButton()` (which rendered a
    /// confusing "Edit" inside a sheet already titled "Edit Task"): the Subtasks
    /// section header toggles edit mode only while the user is actually reordering.
    @State private var subtaskEditMode: EditMode = .inactive

    @State private var title: String
    @State private var description: String
    @State private var quadrant: Quadrant
    @State private var tags: [String]
    @State private var tagDraft = ""
    @State private var saveError: String?
    // C2 — due date + recurrence
    @State private var dueDate: Date?
    @State private var recurrence: RecurrenceType
    @State private var snoozedUntil: Date?
    @State private var notificationEnabled: Bool
    @State private var notifyBefore: Int?
    @State private var estimateText: String
    // C3 — subtasks
    @State private var subtasks: [Subtask]
    @State private var subtaskDraft = ""
    // C4 — dependencies
    @State private var dependencies: [String]
    @State private var showingDependencyPicker = false
    /// The task being edited (nil = creating a new one). Saving an edit mutates
    /// THIS value so non-edited (Phase-2) fields survive.
    private let original: Task?
    /// Stable id for this editing session. For new tasks, reserved once so
    /// the dependency graph the picker validates against matches the persisted task (C4).
    private let editingTaskID: String

    init(request: EditorRequest) {
        switch request {
        case .new(let q, let prefill):
            _title = State(initialValue: prefill?.title ?? "")
            _description = State(initialValue: prefill?.descriptionAdditions.joined(separator: "\n") ?? "")
            _quadrant = State(initialValue: prefill.map { Quadrant(urgent: $0.urgent, important: $0.important) } ?? q)
            _tags = State(initialValue: prefill?.tags ?? [])
            _dueDate = State(initialValue: nil)
            _recurrence = State(initialValue: .none)
            _snoozedUntil = State(initialValue: nil)
            _notificationEnabled = State(initialValue: false)
            _notifyBefore = State(initialValue: nil)
            _estimateText = State(initialValue: "")
            _subtasks = State(initialValue: [])
            _dependencies = State(initialValue: [])
            original = nil
            editingTaskID = IDGenerator.generate(size: IDGenerator.Size.task)
        case .edit(let t):
            _title = State(initialValue: t.title)
            _description = State(initialValue: t.description)
            _quadrant = State(initialValue: t.quadrant)
            _tags = State(initialValue: t.tags)
            _dueDate = State(initialValue: t.dueDate)
            _recurrence = State(initialValue: t.recurrence)
            _snoozedUntil = State(initialValue: t.snoozedUntil)
            _notificationEnabled = State(initialValue: t.notificationEnabled && t.dueDate != nil)
            _notifyBefore = State(initialValue: t.notifyBefore)
            _estimateText = State(initialValue: t.estimatedMinutes.map(String.init) ?? "")
            _subtasks = State(initialValue: t.subtasks)
            _dependencies = State(initialValue: t.dependencies)
            original = t
            editingTaskID = t.id
        }
    }

    var body: some View {
        // iPhone: half-height quick edit stays, with an explicit path to the full form.
        // iPad/Mac: a page-sized sheet — the medium detent cut the quadrant picker mid-tile.
        if UIDevice.current.userInterfaceIdiom == .phone {
            editorStack.presentationDetents([.medium, .large], selection: $detent)
        } else {
            editorStack.presentationSizing(.page)
        }
    }

    private var editorStack: some View {
        NavigationStack {
            Form {
                Group {
                    Section {
                        TextField(String(localized: "Title"), text: $title)
                            .onChange(of: title) { _, _ in saveError = nil }
                    }
                    Section(String(localized: "Quadrant")) { quadrantPicker }
                    Section(String(localized: "Tags")) { tagField }
                    Section(String(localized: "Notes")) {
                        TextField(String(localized: "Description"), text: $description, axis: .vertical)
                            .lineLimit(3...8)
                    }
                    linksSection
                    dueDateSection
                    recurrenceSection
                }
                Group {
                    subtasksSection
                    estimateSection
                    snoozeSection
                    dependenciesSection
                    reminderSection
                    if let saveError {
                        Section { Text(saveError).font(.caption).foregroundStyle(Surface.alert) }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .accessibilityIdentifier("task-editor")
            .tint(Surface.tint)   // baseline calm action tint (carets + true actions, never system blue); picker values → ink3 by role
            .environment(\.editMode, $subtaskEditMode)
            .safeAreaInset(edge: .bottom) {
                if UIDevice.current.userInterfaceIdiom == .phone && detent == .medium {
                    showAllDetailsButton
                }
            }
            .navigationTitle(original == nil ? String(localized: "New Task") : String(localized: "Edit Task"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                        .accessibilityIdentifier("editor-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("editor-save")
                }
            }
        }
        .sheet(isPresented: $showingDependencyPicker) {
            DependencyPickerView(
                editingTaskID: editingTaskID,
                currentDependencies: dependencies,
                onPick: { dependencies.append($0) }
            )
            .environment(store)  // Catalyst: re-inject store across the (nested) sheet boundary
        }
    }

    /// Visible only at the iPhone medium detent: due date, subtasks, dependencies and
    /// more live below the fold, and the grabber alone doesn't say so.
    private var showAllDetailsButton: some View {
        Button {
            withAnimation { detent = .large }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.up")
                Text(String(localized: "Show all details"))
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Surface.tint)
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Surface.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(Surface.hairline, lineWidth: 1))
            .shadow(color: Surface.shadow.opacity(0.10), radius: 8, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .accessibilityHint(String(localized: "Expands the editor to show every section"))
    }

    /// 2×2 picker mirroring the matrix. Each cell shows its quadrant icon + name in
    /// the quadrant accent; the selected cell fills with the quadrant wash + a full
    /// accent border, unselected cells carry only a faint accent-tinted border (§3).
    private var quadrantPicker: some View {
        LazyVGrid(columns: [GridItem(), GridItem()], spacing: 10) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                let selected = quadrant == q
                Button { quadrant = q } label: {
                    VStack(spacing: 8) {
                        Image(systemName: QuadrantStyle.symbol(q)).font(.title3)
                        Text(q.title).font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(QuadrantStyle.accent(q))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16).padding(.horizontal, 10)
                    .background(selected ? QuadrantStyle.wash(q) : Surface.surface,
                                in: RoundedRectangle(cornerRadius: Radius.input, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.input, style: .continuous)
                            .strokeBorder(QuadrantStyle.accent(q).opacity(selected ? 1 : 0.35),
                                          lineWidth: selected ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .listRowBackground(Color.clear)
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                HStack(spacing: 8) {
                    ForEach(tags, id: \.self) { tag in tagChip(tag) }
                }
            }
            HStack {
                TextField(String(localized: "Add tag"), text: $tagDraft)
                    .onSubmit(addTag)
                    .onChange(of: tagDraft) { _, new in if new.hasSuffix(",") { addTag() } }
                Button(String(localized: "Add"), action: addTag)
                    .disabled(tagDraft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).isEmpty
                              || tags.count >= FieldLimits.maxTags)
            }
        }
    }

    /// An editable tag chip: the app's canonical wash capsule (matching `TaskCardView.tagRow`
    /// and `CaptureBar`, tinted by the editor's current `quadrant`) plus a distinct, comfortably-
    /// tappable remove control — replacing the old sub-44pt inline "✕" glyph glued to the label.
    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#\(tag)").font(.footnote)
            Button {
                tags.removeAll { $0 == tag }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .frame(width: 28, height: 28)   // comfortable hit target, not a 10pt glyph
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Remove tag \(tag)"))
        }
        .foregroundStyle(QuadrantStyle.accent(quadrant))
        .padding(.leading, 10).padding(.trailing, 2)
        .background(QuadrantStyle.wash(quadrant), in: Capsule())
    }

    /// Read-only, tappable links detected in the description (design-spec 2026-06-24).
    /// Each label *is* its own URL (no spoofing), and `Link` opens the system browser
    /// via the environment `openURL`. Validation happens in `LinkDetector`/`URLSanitizer`
    /// (http/https only) — this view never hands an unvetted URL to the OS. Renders
    /// nothing when the description holds no safe URL.
    @ViewBuilder private var linksSection: some View {
        let links = LinkDetector.detect(in: description)
        if !links.isEmpty {
            Section(String(localized: "Links")) {
                ForEach(links, id: \.self) { url in
                    Link(destination: url) {
                        Label {
                            Text(verbatim: url.absoluteString)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } icon: {
                            Image(systemName: "link")
                        }
                        .font(.subheadline)
                        .foregroundStyle(Surface.tint)
                    }
                    .accessibilityHint(String(localized: "Opens in your browser"))
                }
            }
        }
    }

    private var dueDateSection: some View {
        Section(String(localized: "Due Date")) {
            Toggle(String(localized: "Has due date"), isOn: Binding(
                get: { dueDate != nil },
                set: { dueDate = $0 ? (dueDate ?? Calendar.current.startOfDay(for: .now)) : nil }
            ))
            .tint(Surface.success)
            if dueDate != nil {
                DatePicker(String(localized: "Due"),
                           selection: Binding(get: { dueDate ?? .now }, set: { dueDate = $0 }),
                           displayedComponents: .date)
            }
            HStack(spacing: 8) {
                ForEach(DueDatePreset.allCases, id: \.self) { preset in
                    let resolved = DueDatePresets.resolve(preset, today: .now, calendar: .current)
                    let isSelected = sameDay(dueDate, resolved)
                    Button(preset.label) {
                        dueDate = resolved
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? QuadrantStyle.accent(.notUrgentImportant) : Surface.tint)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(isSelected ? QuadrantStyle.wash(.notUrgentImportant) : Surface.sunken,
                                in: Capsule())
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var recurrenceSection: some View {
        Section(String(localized: "Repeat")) {
            Picker(String(localized: "Recurrence"), selection: $recurrence) {
                ForEach(RecurrenceType.allCases, id: \.self) { kind in
                    Text(recurrenceLabel(kind)).tag(kind)
                }
            }
            .tint(Surface.ink3)   // value (e.g. "Never") reads graphite, not tide
        }
    }

    private var subtasksSection: some View {
        Section {
            ForEach($subtasks) { $subtask in
                HStack {
                    Button {
                        subtask.completed.toggle()
                    } label: {
                        Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(subtask.completed ? String(localized: "Mark incomplete") : String(localized: "Mark complete"))
                    .accessibilityHint(subtask.title)
                    TextField(String(localized: "Subtask"), text: $subtask.title)
                        .strikethrough(subtask.completed)
                }
            }
            .onDelete { subtasks.remove(atOffsets: $0) }
            .onMove { subtasks.move(fromOffsets: $0, toOffset: $1) }
            HStack {
                TextField(String(localized: "Add subtask"), text: $subtaskDraft)
                    .onSubmit(addSubtask)
                Button(String(localized: "Add"), action: addSubtask)
                    .disabled(subtaskDraft.trimmingCharacters(in: .whitespaces).isEmpty
                              || subtasks.count >= FieldLimits.maxSubtasks)
            }
        } header: {
            HStack {
                Text(String(localized: "Subtasks"))
                Spacer()
                if subtasks.count > 1 {
                    Button(subtaskEditMode.isEditing
                           ? String(localized: "Done")
                           : String(localized: "Reorder")) {
                        withAnimation { subtaskEditMode = subtaskEditMode.isEditing ? .inactive : .active }
                    }
                    .font(.footnote)
                    .textCase(nil)
                }
            }
        }
    }

    private var estimateSection: some View {
        Section(String(localized: "Estimate")) {
            HStack {
                TextField(String(localized: "Minutes"), text: $estimateText)
                    .keyboardType(.numberPad)
                Spacer()
                Text(trackedReadout).font(.caption).foregroundStyle(trackedColor)
            }
        }
    }

    private var snoozeSection: some View {
        Section(String(localized: "Snooze")) {
            if let snoozedUntil, snoozedUntil > .now {
                HStack {
                    Text(RelativeDate.remainingString(until: snoozedUntil))
                    Spacer()
                    Button(String(localized: "Clear"), role: .destructive) {
                        self.snoozedUntil = nil
                    }
                }
            }
            Menu(String(localized: "Snooze for…")) {
                ForEach(snoozeMenuPresets, id: \.0) { label, preset in
                    Button(label) {
                        snoozedUntil = Date.now.addingTimeInterval(
                            min(preset.interval, FieldLimits.maxSnoozeInterval))
                    }
                }
            }
        }
    }

    /// Reminder controls (product spec §9) — shown only when a due date is set. The picker's
    /// `None` selection disables the reminder; any offset enables it with that `notifyBefore`.
    @ViewBuilder private var reminderSection: some View {
        if dueDate != nil {
            Section(String(localized: "Reminder")) {
                Picker(String(localized: "Remind me"), selection: reminderSelection) {
                    Text(String(localized: "None")).tag(ReminderOption.none)
                    Text(String(localized: "At time of event")).tag(ReminderOption.offset(0))
                    Text(String(localized: "5 minutes before")).tag(ReminderOption.offset(5))
                    Text(String(localized: "15 minutes before")).tag(ReminderOption.offset(15))
                    Text(String(localized: "30 minutes before")).tag(ReminderOption.offset(30))
                    Text(String(localized: "1 hour before")).tag(ReminderOption.offset(60))
                    Text(String(localized: "2 hours before")).tag(ReminderOption.offset(120))
                    Text(String(localized: "1 day before")).tag(ReminderOption.offset(1440))
                }
                .tint(Surface.ink3)   // value graphite
            }
        }
    }

    /// The reminder picker's options. `.none` = no reminder; `.offset(m)` = m minutes before due.
    private enum ReminderOption: Hashable { case none, offset(Int) }

    /// Binds the picker to `notificationEnabled` + `notifyBefore`. Selecting `.none` disables;
    /// selecting an offset enables with that value. When enabled but `notifyBefore` is nil
    /// (legacy/new), the displayed selection falls back to the store's `defaultReminder` — which
    /// is always one of the offered offsets (the picker's offsets `{0,5,15,30,60,120,1440}` are a
    /// superset of `NotificationSettings.allowedReminders` `{15,30,60,120,1440}`, so the Picker
    /// never renders blank). Enabling a reminder requests OS authorization contextually (§9.2:
    /// "when the user … sets a due date with a reminder") — a no-op if already asked/determined.
    private var reminderSelection: Binding<ReminderOption> {
        Binding(
            get: {
                guard notificationEnabled else { return .none }
                return .offset(notifyBefore ?? store.notificationSettings.defaultReminder)
            },
            set: { option in
                switch option {
                case .none:
                    notificationEnabled = false
                    notifyBefore = nil
                case .offset(let minutes):
                    notificationEnabled = true
                    notifyBefore = minutes
                    _Concurrency.Task { await store.requestNotificationAuthorization() }
                }
            }
        )
    }

    private var dependenciesSection: some View {
        Section(String(localized: "Dependencies")) {
            ForEach(dependencies, id: \.self) { depID in
                HStack {
                    Text(store.tasks.first { $0.id == depID }?.title
                         ?? String(localized: "Unknown task"))
                    Spacer()
                    Button(role: .destructive) {
                        dependencies.removeAll { $0 == depID }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "Remove dependency"))
                }
            }
            Button(String(localized: "Add dependency…")) { showingDependencyPicker = true }
                .disabled(dependencies.count >= FieldLimits.maxDependencies)
        }
    }

    /// Whether two optional dates fall on the same calendar day (nil ≍ nil = "None").
    private func sameDay(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return Calendar.current.isDate(x, inSameDayAs: y)
        default: return false
        }
    }

    private func addSubtask() {
        let title = subtaskDraft.trimmingCharacters(in: .whitespaces)
        subtaskDraft = ""
        guard !title.isEmpty, subtasks.count < FieldLimits.maxSubtasks else { return }
        subtasks.append(Subtask(id: IDGenerator.generate(size: IDGenerator.Size.task),
                                title: String(title.prefix(FieldLimits.subtaskTitleRange.upperBound)),
                                completed: false))
    }

    /// "Tracked Xm of Ym estimated" — over-estimate styled in the alert color (§6.9).
    private var trackedMinutes: Int { TimeTracking.timeSpentMinutes(original?.timeEntries ?? []) }
    private var trackedReadout: String {
        let tracked = TimeTracking.format(minutes: trackedMinutes)
        guard let estimate = Int(estimateText), estimate > 0 else {
            return String(localized: "Tracked \(tracked)")
        }
        return String(localized: "Tracked \(tracked) of \(TimeTracking.format(minutes: estimate))")
    }
    private var trackedColor: Color {
        guard let estimate = Int(estimateText), estimate > 0 else { return Surface.ink3 }
        return trackedMinutes > estimate ? Surface.alert : Surface.ink3
    }

    /// The six §6.7 snooze presets, labels localized. (The matrix row in Group D
    /// uses the same list; a six-entry UI literal is clearer duplicated than shared.)
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes),
         (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour),
         (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow),
         (String(localized: "Next week"), .nextWeek)]
    }

    private func recurrenceLabel(_ kind: RecurrenceType) -> String {
        switch kind {
        case .none:    String(localized: "Never")
        case .daily:   String(localized: "Daily")
        case .weekly:  String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }

    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).lowercased()
        tagDraft = ""
        guard !t.isEmpty, FieldLimits.tagLengthRange.contains(t.count), !tags.contains(t), tags.count < FieldLimits.maxTags else { return }
        tags.append(t)
    }

    private func save() {
        // Flush typed-but-unsubmitted draft entries: the tag/subtask fields only commit
        // on return (or a trailing comma, for tags), so tapping Save with a pending draft
        // would otherwise silently drop it. Both adders no-op when their draft is empty.
        addTag()
        addSubtask()
        var task: Task
        if let original {
            task = original
            task.title = title.trimmingCharacters(in: .whitespaces)
            task.description = description
            task.urgent = quadrant.isUrgent
            task.important = quadrant.isImportant
            task.tags = tags
            // C2: due date + recurrence
            task.dueDate = dueDate
            // Phase-4: the editor's reminder controls drive these (§9). Clearing the due date
            // also clears the reminder (a reminder is meaningless without a due date).
            if dueDate == nil {
                task.notificationEnabled = false
                task.notifyBefore = nil
            } else {
                task.notificationEnabled = notificationEnabled
                task.notifyBefore = notificationEnabled ? notifyBefore : nil
            }
            task.recurrence = recurrence
            task.snoozedUntil = snoozedUntil
            task.estimatedMinutes = FieldLimits.normalizedEstimate(Int(estimateText))
            // C3: subtasks
            task.subtasks = subtasks
            // C4: dependencies
            task.dependencies = dependencies
        } else {
            let now = Date.now
            task = Task(id: editingTaskID,
                        title: title.trimmingCharacters(in: .whitespaces),
                        description: description,
                        urgent: quadrant.isUrgent, important: quadrant.isImportant,
                        createdAt: now, updatedAt: now,
                        dueDate: dueDate,
                        recurrence: recurrence,
                        tags: tags,
                        subtasks: subtasks,
                        dependencies: dependencies,
                        notifyBefore: (dueDate != nil && notificationEnabled) ? notifyBefore : nil,
                        notificationEnabled: dueDate != nil && notificationEnabled,
                        snoozedUntil: snoozedUntil,
                        estimatedMinutes: FieldLimits.normalizedEstimate(Int(estimateText)))
        }
        _Concurrency.Task { @MainActor in
            do {
                if original == nil { try await store.create(task) } else { try await store.save(task) }
                dismiss()
            } catch let error as ValidationError {
                saveError = error.message
            } catch {
                saveError = String(localized: "Couldn't save. Please try again.")
            }
        }
    }
}
