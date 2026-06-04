import SwiftUI
import GSDModel
import GSDStore

/// The archive: read-only dimmed task cards. Swipe to Restore (leading) or Delete
/// permanently (trailing, confirmed). Reuses `TaskCardView` at reduced opacity. Search
/// is wired here; bulk multi-select is layered on in Group E. A toolbar menu exposes the
/// auto-archive settings (toggle + 30/60/90-day threshold), re-running the sweep on change.
struct ArchiveListView: View {
    @Environment(TaskStore.self) private var store
    @State private var searchText = ""
    @State private var pendingDelete: Task?
    @State private var selection = Set<String>()
    @State private var showBulkDeleteConfirm = false
    @State private var actionFailure: TaskActionFailure?
    @Environment(\.editMode) private var editMode

    private var results: [Task] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return store.archivedTasks }
        return TaskFilter.apply(FilterCriteria(searchQuery: searchText),
                                to: store.archivedTasks, now: .now, calendar: .current)
    }

    var body: some View {
        Group {
            if store.archivedTasks.isEmpty {
                ContentUnavailableView(String(localized: "Archive is empty"),
                                       systemImage: "archivebox",
                                       description: Text(String(localized: "Completed tasks you archive will appear here.")))
            } else {
                List(selection: $selection) {
                    ForEach(results) { task in
                        TaskCardView(task: task, now: .now, blockedByCount: 0, blockingCount: 0)
                            .opacity(0.6)
                            .tag(task.id)
                            .swipeActions(edge: .leading) {
                                Button {
                                    runArchiveAction(String(localized: "Couldn’t restore that task")) {
                                        try await store.restore(task)
                                    }
                                } label: { Label(String(localized: "Restore"), systemImage: "arrow.uturn.backward") }
                                .tint(.blue)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { pendingDelete = task } label: {
                                    Label(String(localized: "Delete"), systemImage: "trash")
                                }
                            }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(String(localized: "Archive"))
        .searchable(text: $searchText, prompt: String(localized: "Search archive"))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { archiveSettingsMenu }
            ToolbarItem(placement: .topBarLeading) { EditButton() }
        }
        // Slim bulk bar: archive has no move/tags/due semantics, only Restore + Delete.
        // Hosted via safeAreaInset so its confirmation presents reliably.
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                HStack {
                    Button(String(localized: "Restore")) {
                        let ids = selection
                        runArchiveAction(String(localized: "Couldn’t restore selected tasks")) {
                            for task in store.archivedTasks where ids.contains(task.id) {
                                try await store.restore(task)
                            }
                        } onSuccess: {
                            selection.subtract(ids)
                        }
                    }
                    Spacer()
                    Text(String(localized: "\(selection.count) selected"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(String(localized: "Delete"), role: .destructive) { showBulkDeleteConfirm = true }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)
            }
        }
        .confirmationDialog(String(localized: "Delete \(selection.count) tasks permanently?"),
                            isPresented: $showBulkDeleteConfirm, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) {
                let ids = selection
                runArchiveAction(String(localized: "Couldn’t delete selected tasks")) {
                    for task in store.archivedTasks where ids.contains(task.id) {
                        try await store.deletePermanently(task)
                    }
                } onSuccess: {
                    selection.subtract(ids)
                }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This can't be undone."))
        }
        .confirmationDialog(String(localized: "Delete permanently?"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let task = pendingDelete {
                    runArchiveAction(String(localized: "Couldn’t delete that task")) {
                        try await store.deletePermanently(task)
                    }
                }
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(String(localized: "This can't be undone."))
        }
        .onChange(of: editMode?.wrappedValue) { _, mode in
            if mode?.isEditing == false { selection.removeAll() }
        }
        .taskActionFailureAlert($actionFailure)
    }

    @ViewBuilder private var archiveSettingsMenu: some View {
        Menu {
            Toggle(String(localized: "Auto-archive"), isOn: Binding(
                get: { store.archiveSettings.autoEnabled },
                set: { var s = store.archiveSettings; s.autoEnabled = $0; store.archiveSettings = s
                       runArchiveAction(String(localized: "Couldn’t run auto-archive")) {
                           try await store.runAutoArchiveSweep()
                       } }))
            Picker(String(localized: "Archive after"), selection: Binding(
                get: { store.archiveSettings.afterDays },
                set: { var s = store.archiveSettings; s.afterDays = $0; store.archiveSettings = s
                       runArchiveAction(String(localized: "Couldn’t run auto-archive")) {
                           try await store.runAutoArchiveSweep()
                       } })) {
                ForEach(ArchiveSettings.allowedDays, id: \.self) { Text("\($0) days").tag($0) }
            }
        } label: { Label(String(localized: "Archive settings"), systemImage: "gearshape") }
    }

    private func runArchiveAction(
        _ failureMessage: String,
        operation: @escaping () async throws -> Void,
        onSuccess: @escaping () -> Void = {}
    ) {
        _Concurrency.Task { @MainActor in
            do {
                try await operation()
                onSuccess()
            } catch {
                actionFailure = TaskActionFailure("\(failureMessage): \(error.localizedDescription)")
            }
        }
    }
}
