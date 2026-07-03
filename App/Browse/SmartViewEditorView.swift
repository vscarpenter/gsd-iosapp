import SwiftUI
import GSDModel
import GSDStore

/// What the smart-view editor sheet was opened to do. `Identifiable` drives `.sheet(item:)`.
enum SmartViewEditorTarget: Identifiable {
    case create
    case edit(SmartView)
    var id: String {
        switch self {
        case .create: "create"
        case .edit(let v): v.id
        }
    }
}

/// Create or edit a CUSTOM smart view: name + icon + a full FilterCriteria editor
/// (every editable §5.9 field). Built-ins are never editable (they never open this).
struct SmartViewEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String
    @State private var criteria: FilterCriteria
    @State private var tagDraft = ""
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var saveError: String?
    @State private var isSaving = false

    private let editingID: String?

    /// SF Symbols offered for a custom view (a small curated set; keeps the picker simple).
    private let iconChoices = ["star", "flag", "bolt", "tag", "tray.full", "list.bullet",
                               "calendar", "clock", "checkmark.circle", "exclamationmark.triangle"]
    private let maxNameLength = 60

    /// Human-readable VoiceOver labels for each icon choice.
    private let iconLabels: [String: String] = [
        "star": String(localized: "Star"),
        "flag": String(localized: "Flag"),
        "bolt": String(localized: "Lightning bolt"),
        "tag": String(localized: "Tag"),
        "tray.full": String(localized: "Inbox"),
        "list.bullet": String(localized: "List"),
        "calendar": String(localized: "Calendar"),
        "clock": String(localized: "Clock"),
        "checkmark.circle": String(localized: "Checkmark"),
        "exclamationmark.triangle": String(localized: "Warning"),
    ]

    init(target: SmartViewEditorTarget) {
        switch target {
        case .create:
            _name = State(initialValue: "")
            _icon = State(initialValue: "star")
            _criteria = State(initialValue: FilterCriteria())
            _hasStart = State(initialValue: false)
            _hasEnd = State(initialValue: false)
            editingID = nil
        case .edit(let view):
            _name = State(initialValue: view.name)
            _icon = State(initialValue: view.icon)
            _criteria = State(initialValue: view.criteria)
            _hasStart = State(initialValue: view.criteria.dueDateRange?.start != nil)
            _hasEnd = State(initialValue: view.criteria.dueDateRange?.end != nil)
            editingID = view.id
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Name")) {
                    TextField(String(localized: "Smart view name"), text: $name)
                        .onChange(of: name) { _, _ in saveError = nil }
                }
                Section(String(localized: "Icon")) { iconPicker }
                Section(String(localized: "Status")) { statusPicker }
                Section(String(localized: "Quadrants")) { quadrantChips }
                Section(String(localized: "Tags")) { tagField }
                Section(String(localized: "Due")) { duePredicateToggles }
                Section(String(localized: "Due date range")) { dueRangePickers }
                Section(String(localized: "Recurrence")) { recurrenceChips }
                Section { readyToggle }
                Section(String(localized: "Search text")) {
                    TextField(String(localized: "Contains…"), text: $criteria.searchQuery)
                }
                if let saveError {
                    Section { Text(saveError).font(.caption).foregroundStyle(Surface.alert) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .tint(Surface.tint)
            .navigationTitle(editingID == nil ? String(localized: "New Smart View") : String(localized: "Edit Smart View"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var iconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(iconChoices, id: \.self) { choice in
                    Button { icon = choice } label: {
                        Image(systemName: choice)
                            .foregroundStyle(icon == choice ? Surface.tint : Surface.ink2)
                            .frame(width: 44, height: 44)
                            .background(icon == choice ? Surface.tint.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    }
                    .accessibilityLabel(iconLabels[choice] ?? choice)
                    .accessibilityAddTraits(icon == choice ? .isSelected : [])
                }
            }
        }
    }

    private var statusPicker: some View {
        Picker(String(localized: "Status"), selection: $criteria.status) {
            ForEach(FilterCriteria.Status.allCases, id: \.self) { status in
                Text(statusLabel(status)).tag(status)
            }
        }
        .pickerStyle(.segmented)
    }

    private var quadrantChips: some View {
        LazyVGrid(columns: [GridItem(), GridItem()], spacing: 8) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                let on = criteria.quadrants.contains(q)
                Button { toggle(q, in: \.quadrants) } label: {
                    Label(q.title, systemImage: QuadrantStyle.symbol(q))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(8)
                        .background(on ? QuadrantStyle.accent(q).opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .tint(QuadrantStyle.accent(q))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !criteria.tags.isEmpty {
                HStack {
                    ForEach(criteria.tags, id: \.self) { tag in
                        Button { criteria.tags.removeAll { $0 == tag } } label: { Text("#\(tag)  ✕").font(.caption2) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            TextField(String(localized: "Add tag"), text: $tagDraft).onSubmit(addTag)
        }
    }

    private var duePredicateToggles: some View {
        Group {
            Toggle(String(localized: "Overdue"), isOn: $criteria.overdue)
            Toggle(String(localized: "Due today"), isOn: $criteria.dueToday)
            Toggle(String(localized: "Due this week"), isOn: $criteria.dueThisWeek)
            Toggle(String(localized: "No due date"), isOn: $criteria.noDueDate)
        }
        .tint(Surface.tint)   // toggles read the single interactive tint, not a third "on" color
    }

    private var dueRangePickers: some View {
        Group {
            Toggle(String(localized: "From date"), isOn: $hasStart)
            if hasStart {
                DatePicker(String(localized: "Start"),
                           selection: Binding(get: { criteria.dueDateRange?.start ?? .now },
                                              set: { setRange(start: $0) }),
                           displayedComponents: .date)
            }
            Toggle(String(localized: "To date"), isOn: $hasEnd)
            if hasEnd {
                DatePicker(String(localized: "End"),
                           selection: Binding(get: { criteria.dueDateRange?.end ?? .now },
                                              set: { setRange(end: $0) }),
                           displayedComponents: .date)
            }
        }
        .onChange(of: hasStart) { _, on in if !on { setRange(start: nil) } else { setRange(start: criteria.dueDateRange?.start ?? .now) } }
        .onChange(of: hasEnd) { _, on in if !on { setRange(end: nil) } else { setRange(end: criteria.dueDateRange?.end ?? .now) } }
        .tint(Surface.tint)   // toggles read the single interactive tint, not a third "on" color
    }

    private var recurrenceChips: some View {
        HStack {
            ForEach([RecurrenceType.daily, .weekly, .monthly], id: \.self) { kind in
                let on = criteria.recurrence.contains(kind)
                Button { toggle(kind, in: \.recurrence) } label: {
                    Text(recurrenceLabel(kind))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? Surface.tint.opacity(0.16) : Color.clear,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var readyToggle: some View {
        Toggle(String(localized: "Ready to work (no incomplete blockers)"), isOn: $criteria.readyToWork)
            .tint(Surface.tint)   // toggles read the single interactive tint, not a third "on" color
    }

    // MARK: Helpers

    private func toggle(_ value: Quadrant, in keyPath: WritableKeyPath<FilterCriteria, [Quadrant]>) {
        if criteria[keyPath: keyPath].contains(value) { criteria[keyPath: keyPath].removeAll { $0 == value } }
        else { criteria[keyPath: keyPath].append(value) }
    }
    private func toggle(_ value: RecurrenceType, in keyPath: WritableKeyPath<FilterCriteria, [RecurrenceType]>) {
        if criteria[keyPath: keyPath].contains(value) { criteria[keyPath: keyPath].removeAll { $0 == value } }
        else { criteria[keyPath: keyPath].append(value) }
    }
    private func setRange(start: Date) { setRange(start: .some(start)) }
    private func setRange(start: Date?) {
        var range = criteria.dueDateRange ?? .init()
        range.start = start
        criteria.dueDateRange = (range.start == nil && range.end == nil) ? nil : range
    }
    private func setRange(end: Date) { setRange(end: .some(end)) }
    private func setRange(end: Date?) {
        var range = criteria.dueDateRange ?? .init()
        range.end = end
        criteria.dueDateRange = (range.start == nil && range.end == nil) ? nil : range
    }
    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).lowercased()
        tagDraft = ""
        guard !t.isEmpty, FieldLimits.tagLengthRange.contains(t.count),
              !criteria.tags.contains(t), criteria.tags.count < FieldLimits.maxTags else { return }
        criteria.tags.append(t)
    }
    private func statusLabel(_ s: FilterCriteria.Status) -> String {
        switch s {
        case .all: String(localized: "All")
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        }
    }
    private func recurrenceLabel(_ kind: RecurrenceType) -> String {
        switch kind {
        case .none: String(localized: "Never")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { saveError = String(localized: "Name is required."); return }
        guard trimmed.count <= maxNameLength else {
            saveError = String(localized: "Name must be 60 characters or fewer."); return
        }
        guard !isSaving else { return }
        isSaving = true
        _Concurrency.Task { @MainActor in
            defer { isSaving = false }
            do {
                if let editingID {
                    try await store.updateView(SmartView(id: editingID, name: trimmed, icon: icon,
                                                          criteria: criteria, isBuiltIn: false))
                } else {
                    try await store.createView(name: trimmed, icon: icon, criteria: criteria)
                }
                dismiss()
            } catch {
                saveError = String(localized: "Couldn't save. Please try again.")
            }
        }
    }
}
