import SwiftUI
import GSDModel
import GSDStore

enum SavedEditorTarget: Identifiable {
    case notes(Task)
    case returnToMatrix(Task)

    var task: Task { switch self { case .notes(let task), .returnToMatrix(let task): task } }
    var isNotes: Bool { if case .notes = self { true } else { false } }
    var id: String { "\(task.id)-\(isNotes ? "notes" : "return")" }
}

struct SavedEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @FocusState private var notesFocused: Bool
    @State private var notes: String
    @State private var quadrant: Quadrant
    @State private var dueDate: Date?
    @State private var isSaving = false
    @State private var failure: TaskActionFailure?
    let target: SavedEditorTarget
    /// Runs after a save succeeds, before the sheet closes. The weekly sweep moves on from here.
    var onSaved: (() -> Void)?

    init(target: SavedEditorTarget, onSaved: (() -> Void)? = nil) {
        self.target = target
        self.onSaved = onSaved
        _notes = State(initialValue: target.task.description)
        _quadrant = State(initialValue: target.task.quadrant)
        _dueDate = State(initialValue: target.task.dueDate)
    }

    /// The time picked when All day is switched off, matching the task editor.
    private static let defaultDueTime: (hour: Int, minute: Int) = (9, 0)

    private var notesTooLong: Bool { notes.utf16.count > FieldLimits.descriptionMax }

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(target.task.title).font(.serif(.title3)).foregroundStyle(Surface.ink) }
                    .listRowBackground(Surface.surface)
                if target.isNotes { notesSection } else { returnSection }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .tint(Surface.tint)
            .navigationTitle(target.isNotes ? String(localized: "Notes") : String(localized: "Return to matrix"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }.disabled(isSaving)
                }
                if target.isNotes {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(isSaving ? String(localized: "Saving…") : String(localized: "Save"), action: save)
                            .disabled(isSaving || notesTooLong || notes == target.task.description)
                            .accessibilityIdentifier("saved-editor-save")
                    }
                }
            }
            .editorBarNeverMinimizes()
        }
        .interactiveDismissDisabled(isSaving)
        .presentationDetents([.large])
        .presentationSizing(.form)
        .taskActionFailureAlert($failure)
        .onAppear { notesFocused = target.isNotes }
        .accessibilityIdentifier("saved-editor")
    }

    private var notesSection: some View {
        Section {
            TextEditor(text: $notes)
                .frame(minHeight: 160)
                .focused($notesFocused)
                .accessibilityLabel(String(localized: "Notes and links"))
                .accessibilityIdentifier("saved-notes-field")
            Text(String(localized: "\(notes.utf16.count) of \(FieldLimits.descriptionMax) characters"))
                .font(.caption).foregroundStyle(notesTooLong ? Surface.alert : Surface.ink2)
                .accessibilityIdentifier("saved-notes-count")
        } header: {
            Text(String(localized: "Notes and links"))
        } footer: {
            Text(String(localized: "Keep a short annotation or link. Notes sync with the web when cloud sync is enabled."))
        }
        .listRowBackground(Surface.surface)
    }

    private var returnSection: some View {
        Group {
            Section {
                Picker(String(localized: "Quadrant"), selection: $quadrant) {
                    ForEach(Quadrant.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("saved-return-quadrant")
                // As in the task editor: a new due date starts all day today (D-1), not at this minute.
                Toggle(String(localized: "Set a due date"), isOn: Binding(
                    get: { dueDate != nil },
                    set: { dueDate = $0 ? (dueDate ?? Calendar.current.startOfDay(for: .now)) : nil }
                ))
                if let due = dueDate { dueFields(due) }
            } footer: {
                Text(String(localized: "Review the quadrant and date before making this an active task again."))
            }
            .listRowBackground(Surface.surface)
            Section {
                Button(isSaving ? String(localized: "Adding…") : String(localized: "Add to matrix"), action: save)
                    .disabled(isSaving)
                    .accessibilityIdentifier("saved-editor-save")
            }
            .listRowBackground(Surface.surface)
        }
    }

    /// Date, All day, and time, with the task editor's rules: picking a day keeps the time already
    /// set, and All day is a due date at local midnight (D-1).
    @ViewBuilder private func dueFields(_ due: Date) -> some View {
        DatePicker(String(localized: "Due date"),
                   selection: Binding(get: { due }, set: { picked in
                       dueDate = DueTime.onDate(due, to: Calendar.current.dateComponents([.year, .month, .day], from: picked),
                                                calendar: .current)
                   }),
                   displayedComponents: .date)
        Toggle(String(localized: "All day"), isOn: Binding(
            get: { DueTime.isAllDay(due, calendar: .current) },
            set: { allDay in dueDate = DueTime.atTime(due, allDay ? nil : Self.defaultDueTime, calendar: .current) }
        ))
        if !DueTime.isAllDay(due, calendar: .current) {
            DatePicker(String(localized: "Due time"),
                       selection: Binding(get: { due }, set: { picked in
                           let time = Calendar.current.dateComponents([.hour, .minute], from: picked)
                           dueDate = DueTime.atTime(due, (time.hour ?? 0, time.minute ?? 0), calendar: .current)
                       }),
                       displayedComponents: .hourAndMinute)
        }
    }

    private func save() {
        guard !isSaving, !target.isNotes || !notesTooLong else { return }
        isSaving = true
        _Concurrency.Task { @MainActor in
            do {
                if target.isNotes { try await store.updateSavedNotes(id: target.task.id, notes: notes) }
                else { try await store.returnToMatrix(id: target.task.id, quadrant: quadrant, dueDate: dueDate) }
                onSaved?()
                dismiss()
            } catch {
                // The base string, as on web, with no raw error appended (S9).
                failure = TaskActionFailure(target.isNotes ? error.localizedDescription
                                            : String(localized: "Couldn’t return this item to the matrix"))
                isSaving = false
            }
        }
    }
}
