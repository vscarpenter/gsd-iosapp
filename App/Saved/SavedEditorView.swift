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
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var isSaving = false
    @State private var failure: TaskActionFailure?
    let target: SavedEditorTarget

    init(target: SavedEditorTarget) {
        self.target = target
        _notes = State(initialValue: target.task.description)
        _quadrant = State(initialValue: target.task.quadrant)
        _hasDueDate = State(initialValue: target.task.dueDate != nil)
        _dueDate = State(initialValue: target.task.dueDate ?? .now)
    }

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
                Toggle(String(localized: "Set a due date"), isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker(String(localized: "Due date"), selection: $dueDate, displayedComponents: [.date, .hourAndMinute])
                }
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

    private func save() {
        guard !isSaving, !target.isNotes || !notesTooLong else { return }
        isSaving = true
        _Concurrency.Task { @MainActor in
            do {
                if target.isNotes { try await store.updateSavedNotes(id: target.task.id, notes: notes) }
                else { try await store.returnToMatrix(id: target.task.id, quadrant: quadrant, dueDate: hasDueDate ? dueDate : nil) }
                dismiss()
            } catch {
                failure = TaskActionFailure(error.localizedDescription)
                isSaving = false
            }
        }
    }
}
