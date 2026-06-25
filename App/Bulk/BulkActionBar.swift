import SwiftUI
import GSDModel
import GSDStore

/// Adds the multi-select bulk action bar to a task list. Six ops; Delete confirms.
/// Move/tags/due open lightweight prompts. Each op calls the store's bulk method then
/// clears only the IDs the store reports as resolved.
///
/// The *visual* bar is hosted via `.safeAreaInset(edge: .bottom)` (so it reserves space and
/// never covers the last row), but every `.confirmationDialog`/`.alert`/`.sheet` prompt is
/// attached to the **main content**, not the inset. This split is the whole point:
/// presenting a modal from inside a `.safeAreaInset` is owned by a secondary
/// `UIHostingController` that UIKit reparents — it logs
/// "Adding '_UIReparentingView' as a subview of UIHostingController.view is not supported"
/// and the prompt silently fails to present. `ArchiveListView`'s working bulk-delete uses the
/// same split (bar in the inset, dialog on the content); this modifier generalizes it.
extension View {
    /// Attach the bulk action bar + its prompts to a task list.
    /// - Parameters:
    ///   - selection: the list's multi-select set; the bar clears resolved IDs from it.
    ///   - failure: the parent's failure surface, reused so there's one alert host.
    func bulkActionBar(selection: Binding<Set<String>>,
                       failure: Binding<TaskActionFailure?>) -> some View {
        modifier(BulkActionBarModifier(selection: selection, failure: failure))
    }
}

private struct BulkActionBarModifier: ViewModifier {
    @Environment(TaskStore.self) private var store
    @Binding var selection: Set<String>
    @Binding var failure: TaskActionFailure?

    private enum DeferredPrompt: Sendable {
        case delete
        case move
        case addTags
        case removeTags
        case setDue
    }

    @State private var showDeleteConfirm = false
    @State private var showMove = false
    @State private var showAddTags = false
    @State private var showRemoveTags = false
    @State private var showSetDue = false
    @State private var promptSelection = Set<String>()
    @State private var tagDraft = ""
    @State private var dueDraft = Date.now

    private var count: Int { selection.count }
    private var isPresentingPrompt: Bool {
        showDeleteConfirm || showMove || showAddTags || showRemoveTags || showSetDue
    }
    private var shouldShowBar: Bool { !selection.isEmpty || isPresentingPrompt || !promptSelection.isEmpty }
    private var displayCount: Int { promptSelection.isEmpty ? count : promptSelection.count }

    func body(content: Content) -> some View {
        content
            // The bar's visual lives in the inset…
            .safeAreaInset(edge: .bottom) { bar }
            // …but its prompts are attached to the main content so they actually present.
            .confirmationDialog(String(localized: "Delete \(displayCount) tasks?"),
                                isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button(String(localized: "Delete"), role: .destructive) {
                    run(ids: promptSelection) { try await store.bulkDelete(ids: $0) }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .confirmationDialog(String(localized: "Move to…"), isPresented: $showMove, titleVisibility: .visible) {
                ForEach(Quadrant.allCases, id: \.self) { q in
                    Button(q.title) {
                        run(ids: promptSelection) { try await store.bulkMove(ids: $0, to: q) }
                    }
                }
                Button(String(localized: "Cancel"), role: .cancel) {}
            }
            .alert(String(localized: "Add tags"), isPresented: $showAddTags) {
                TextField(String(localized: "comma,separated"), text: $tagDraft)
                Button(String(localized: "Add")) {
                    let tags = parseTags(tagDraft)
                    let ids = promptSelection
                    tagDraft = ""
                    run(ids: ids) { try await store.bulkAddTags(ids: $0, tags: tags) }
                }
                Button(String(localized: "Cancel"), role: .cancel) { tagDraft = "" }
            }
            .alert(String(localized: "Remove tags"), isPresented: $showRemoveTags) {
                TextField(String(localized: "comma,separated"), text: $tagDraft)
                Button(String(localized: "Remove")) {
                    let tags = parseTags(tagDraft)
                    let ids = promptSelection
                    tagDraft = ""
                    run(ids: ids) { try await store.bulkRemoveTags(ids: $0, tags: tags) }
                }
                Button(String(localized: "Cancel"), role: .cancel) { tagDraft = "" }
            }
            .sheet(isPresented: $showSetDue) {
                NavigationStack {
                    DatePicker(String(localized: "Due"), selection: $dueDraft, displayedComponents: .date)
                        .datePickerStyle(.graphical).padding()
                        .navigationTitle(String(localized: "Set due date"))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(String(localized: "Set")) {
                                    let ids = promptSelection
                                    showSetDue = false
                                    run(ids: ids) { try await store.bulkSetDue(ids: $0, to: dueDraft) }
                                }
                            }
                            ToolbarItem(placement: .cancellationAction) {
                                Button(String(localized: "Cancel")) { showSetDue = false }
                            }
                        }
                }
                .presentationDetents([.medium])
            }
            .onChange(of: showDeleteConfirm) { _, showing in if !showing { clearPromptIfIdle() } }
            .onChange(of: showMove) { _, showing in if !showing { clearPromptIfIdle() } }
            .onChange(of: showAddTags) { _, showing in
                if !showing {
                    tagDraft = ""
                    clearPromptIfIdle()
                }
            }
            .onChange(of: showRemoveTags) { _, showing in
                if !showing {
                    tagDraft = ""
                    clearPromptIfIdle()
                }
            }
            .onChange(of: showSetDue) { _, showing in if !showing { clearPromptIfIdle() } }
    }

    /// Bottom action bar shown while multi-selecting active tasks.
    @ViewBuilder private var bar: some View {
        if shouldShowBar {
            HStack(spacing: 16) {
                Button { run { try await store.bulkComplete(ids: $0) } } label: {
                    Label(String(localized: "Complete"), systemImage: "checkmark.circle")
                }
                Menu {
                    Button(String(localized: "Move to quadrant…")) { presentPrompt(.move) }
                    Button(String(localized: "Add tags…")) { presentPrompt(.addTags) }
                    Button(String(localized: "Remove tags…")) { presentPrompt(.removeTags) }
                    Button(String(localized: "Set due date…")) { presentPrompt(.setDue) }
                } label: { Label(String(localized: "Edit"), systemImage: "slider.horizontal.3") }
                Spacer()
                Text(String(localized: "\(displayCount) selected"))
                    .font(.subheadline)
                    .foregroundStyle(Surface.ink2)
                Spacer()
                Button(role: .destructive) { presentPrompt(.delete) } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            }
            .disabled(selection.isEmpty && promptSelection.isEmpty)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityLabel(String(localized: "\(displayCount) selected"))
        }
    }

    private func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " #")).lowercased()
        }.filter { !$0.isEmpty }
    }

    private func presentPrompt(_ prompt: DeferredPrompt) {
        let ids = selection
        guard !ids.isEmpty else { return }
        promptSelection = ids

        // Menu dismissal is itself a presentation transaction. Start the follow-up
        // prompt on the next main-actor turn so SwiftUI does not immediately tear it down.
        _Concurrency.Task { @MainActor in
            await _Concurrency.Task.yield()
            switch prompt {
            case .delete: showDeleteConfirm = true
            case .move: showMove = true
            case .addTags: showAddTags = true
            case .removeTags: showRemoveTags = true
            case .setDue: showSetDue = true
            }
        }
    }

    private func clearPromptIfIdle() {
        guard !isPresentingPrompt else { return }
        promptSelection.removeAll()
    }

    private func run(
        ids explicitIDs: Set<String>? = nil,
        _ op: @escaping (Set<String>) async throws -> BulkActionResult
    ) {
        let ids = explicitIDs ?? selection
        guard !ids.isEmpty else { return }
        _Concurrency.Task { @MainActor in
            do {
                let result = try await op(ids)
                let unresolvedIDs = ids.subtracting(result.completedIDs)
                if selection.isEmpty {
                    selection = unresolvedIDs
                } else {
                    selection.subtract(result.completedIDs)
                }
                if result.hasFailures {
                    failure = TaskActionFailure(partialFailureMessage(result: result, total: ids.count))
                }
            } catch {
                failure = TaskActionFailure(String(localized: "Couldn’t update selected tasks: \(error.localizedDescription)"))
            }
        }
    }

    private func partialFailureMessage(result: BulkActionResult, total: Int) -> String {
        let failed = result.failures.count
        let completed = max(0, total - failed)
        // completed == 1 is the most common partial-failure shape — don't show "1 tasks".
        let updated = completed == 1
            ? String(localized: "Updated 1 selected task.")
            : String(localized: "Updated \(completed) selected tasks.")
        guard let first = result.failures.first else { return updated }
        if failed == 1 {
            return updated + " " + String(localized: "1 task was skipped: \(first.message)")
        }
        return updated + " " + String(localized: "\(failed) tasks were skipped. First error: \(first.message)")
    }
}
