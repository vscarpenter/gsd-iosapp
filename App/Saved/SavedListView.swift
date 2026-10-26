import SwiftUI
import GSDModel
import GSDStore

struct SavedListView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @Environment(SyncCoordinator.self) private var sync
    @State private var searchText = ""
    @State private var searchPresented = false
    @State private var editor: SavedEditorTarget?
    @State private var failure: TaskActionFailure?

    private var results: [Task] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.savedTasks.filter { task in
            query.isEmpty || ([task.title, task.description] + task.tags).contains { $0.localizedStandardContains(query) }
        }
    }

    var body: some View {
        Group {
            if !store.hasLoadedTasks {
                ProgressView(String(localized: "Loading Saved"))
            } else if store.savedTasks.isEmpty {
                EmptyStateView(icon: "bookmark", title: String(localized: "Nothing saved yet"),
                               message: String(localized: "Choose Move to Saved on a task to keep its notes and links outside the matrix."))
            } else if results.isEmpty {
                EmptyStateView(icon: "magnifyingglass", title: String(localized: "No saved items found"),
                               message: String(localized: "Try a different title, note, or tag."))
            } else {
                savedList
            }
        }
        .background(Surface.paper)
        .navigationTitle(String(localized: "Saved"))
        .navigationBarTitleDisplayMode(.inline)
        .brandedNavigationTitle(String(localized: "Saved"))
        .searchable(text: $searchText, isPresented: $searchPresented,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: String(localized: "Search Saved"))
        .toolbar { paletteButton(palette); syncStatusChip(sync, palette) }
        .onChange(of: palette.focusedSavedTaskID, initial: true) { _, id in
            if id != nil { searchText = ""; searchPresented = false }
        }
        .onChange(of: editor?.id) { _, id in
            if id != nil { searchPresented = false }
        }
        .sheet(item: $editor) { SavedEditorView(target: $0).environment(store) }
        .taskActionFailureAlert($failure)
        .accessibilityIdentifier("saved-library")
    }

    private var savedList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    ForEach(results) { task in
                        SavedRow(task: task, onNotes: { editor = .notes(task) },
                                 onReturn: { editor = .returnToMatrix(task) }, actions: actions)
                            .id(task.id)
                    }
                } header: {
                    Text(String(localized: "Reading, ideas, and reference for later"))
                        .textCase(nil)
                }
            }
            .scrollContentBackground(.hidden)
            .refreshable { await sync.syncNow() }
            .task(id: palette.focusedSavedTaskID) { focusSavedItem(proxy) }
            .onChange(of: results.map(\.id)) { _, _ in focusSavedItem(proxy) }
        }
    }

    private var actions: TaskActions {
        TaskActions(store: store, onCompleted: {}, onError: { failure = TaskActionFailure($0) })
    }

    private func focusSavedItem(_ proxy: ScrollViewProxy) {
        guard let id = palette.focusedSavedTaskID, results.contains(where: { $0.id == id }) else { return }
        proxy.scrollTo(id, anchor: .center)
        palette.focusedSavedTaskID = nil
    }
}

private struct SavedRow: View {
    let task: Task
    let onNotes: () -> Void
    let onReturn: () -> Void
    let actions: TaskActions

    private var links: [String] { CaptureParser.parse(task.description).descriptionAdditions }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onNotes) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title).font(.headline).foregroundStyle(Surface.ink)
                        if !task.description.isEmpty {
                            Text(task.description).font(.subheadline).foregroundStyle(Surface.ink2).lineLimit(3)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(String(localized: "Edit short notes"))
                .accessibilityIdentifier("saved-notes-\(task.id)")
                itemMenu
            }
            ForEach(links, id: \.self) { link in
                if let url = URL(string: link) {
                    Link(destination: url) {
                        Label(url.host() ?? link, systemImage: "arrow.up.right")
                            .font(.subheadline).lineLimit(1)
                    }
                    .tint(Surface.tint)
                    .accessibilityLabel(String(localized: "Open \(link)"))
                }
            }
            if !task.tags.isEmpty {
                Text(task.tags.map { "#\($0)" }.joined(separator: " "))
                    .font(.caption).foregroundStyle(Surface.ink2)
            }
        }
        .padding(.vertical, 6)
        .listRowBackground(Surface.surface)
        .listRowSeparatorTint(Surface.hairline)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("saved-item-\(task.id)")
        .swipeActions(edge: .leading) {
            Button(action: onReturn) { Label(String(localized: "Return to matrix"), systemImage: "arrow.uturn.backward") }
                .tint(Surface.tint)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { actions.delete(task) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                .tint(Surface.alert)
        }
    }

    private var itemMenu: some View {
        Menu {
            Button(action: onNotes) { Label(String(localized: "Edit notes"), systemImage: "pencil") }
            Button(action: onReturn) { Label(String(localized: "Return to matrix"), systemImage: "arrow.uturn.backward") }
            if TimeTracking.runningEntry(task.timeEntries) != nil {
                Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
            }
            ShareLink(item: task.shareText) { Label(String(localized: "Share"), systemImage: "square.and.arrow.up") }
            Button(role: .destructive) { actions.delete(task) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
        } label: {
            Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44).foregroundStyle(Surface.ink2)
        }
        .accessibilityLabel(String(localized: "Actions for \(task.title)"))
        .accessibilityIdentifier("saved-actions-\(task.id)")
    }
}
