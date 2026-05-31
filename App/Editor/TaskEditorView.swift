import SwiftUI
import GSDModel
import GSDStore

struct TaskEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

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
            _estimateText = State(initialValue: t.estimatedMinutes.map(String.init) ?? "")
            _subtasks = State(initialValue: t.subtasks)
            _dependencies = State(initialValue: t.dependencies)
            original = t
            editingTaskID = t.id
        }
    }

    var body: some View {
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
                    dueDateSection
                    recurrenceSection
                }
                Group {
                    subtasksSection
                    estimateSection
                    snoozeSection
                    dependenciesSection
                    if let saveError {
                        Section { Text(saveError).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
            .navigationTitle(original == nil ? String(localized: "New Task") : String(localized: "Edit Task"))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton() }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .sheet(isPresented: $showingDependencyPicker) {
            DependencyPickerView(
                editingTaskID: editingTaskID,
                currentDependencies: dependencies,
                onPick: { dependencies.append($0) }
            )
        }
    }

    private var quadrantPicker: some View {
        LazyVGrid(columns: [GridItem(), GridItem()], spacing: 8) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button { quadrant = q } label: {
                    VStack(spacing: 4) {
                        Image(systemName: QuadrantStyle.symbol(q))
                        Text(q.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .background(quadrant == q ? QuadrantStyle.accent(q).opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(QuadrantStyle.accent(q), lineWidth: quadrant == q ? 2 : 0.5))
                }
                .tint(QuadrantStyle.accent(q))
                .accessibilityAddTraits(quadrant == q ? .isSelected : [])
            }
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: { Text("#\(tag)  ✕").font(.caption2) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            TextField(String(localized: "Add tag"), text: $tagDraft)
                .onSubmit(addTag)
                .onChange(of: tagDraft) { _, new in if new.hasSuffix(",") { addTag() } }
        }
    }

    private var dueDateSection: some View {
        Section(String(localized: "Due Date")) {
            Toggle(String(localized: "Has due date"), isOn: Binding(
                get: { dueDate != nil },
                set: { dueDate = $0 ? (dueDate ?? Calendar.current.startOfDay(for: .now)) : nil }
            ))
            if dueDate != nil {
                DatePicker(String(localized: "Due"),
                           selection: Binding(get: { dueDate ?? .now }, set: { dueDate = $0 }),
                           displayedComponents: .date)
            }
            HStack {
                ForEach(DueDatePreset.allCases, id: \.self) { preset in
                    Button(preset.label) {
                        dueDate = DueDatePresets.resolve(preset, today: .now, calendar: .current)
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
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
        }
    }

    private var subtasksSection: some View {
        Section(String(localized: "Subtasks")) {
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
        guard let estimate = Int(estimateText), estimate > 0 else { return .secondary }
        return trackedMinutes > estimate ? .red : .secondary
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
        var task: Task
        if let original {
            task = original
            task.title = title.trimmingCharacters(in: .whitespaces)
            task.description = description
            task.urgent = quadrant.isUrgent
            task.important = quadrant.isImportant
            task.tags = tags
            // C2: due date + recurrence
            // TODO: Phase-4 — editing dueDate should reset reminder state (§6.3); no reminder UI yet.
            task.dueDate = dueDate
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
