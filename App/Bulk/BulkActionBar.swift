import SwiftUI
import GSDModel
import GSDStore

/// Bottom action bar shown while multi-selecting active tasks. Six ops; Delete confirms.
/// Move/tags/due open lightweight prompts. Each op calls the store's bulk method then
/// clears the selection. Hosted via `.safeAreaInset` (not a toolbar item) so its
/// `.confirmationDialog`/`.alert`/`.sheet` modifiers stay in the main view hierarchy and
/// actually present.
struct BulkActionBar: View {
    @Environment(TaskStore.self) private var store
    @Binding var selection: Set<String>

    @State private var showDeleteConfirm = false
    @State private var showMove = false
    @State private var showAddTags = false
    @State private var showRemoveTags = false
    @State private var showSetDue = false
    @State private var tagDraft = ""
    @State private var dueDraft = Date.now

    private var count: Int { selection.count }

    var body: some View {
        HStack(spacing: 16) {
            Button { run { try await store.bulkComplete(ids: selection) } } label: {
                Label(String(localized: "Complete"), systemImage: "checkmark.circle")
            }
            Menu {
                Button(String(localized: "Move to quadrant…")) { showMove = true }
                Button(String(localized: "Add tags…")) { showAddTags = true }
                Button(String(localized: "Remove tags…")) { showRemoveTags = true }
                Button(String(localized: "Set due date…")) { showSetDue = true }
            } label: { Label(String(localized: "Edit"), systemImage: "slider.horizontal.3") }
            Spacer()
            Text(String(localized: "\(count) selected"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .disabled(selection.isEmpty)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityLabel(String(localized: "\(count) selected"))
        .confirmationDialog(String(localized: "Delete \(count) tasks?"),
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) {
                run { try await store.bulkDelete(ids: selection) }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .confirmationDialog(String(localized: "Move to…"), isPresented: $showMove, titleVisibility: .visible) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { run { try await store.bulkMove(ids: selection, to: q) } }
            }
            Button(String(localized: "Cancel"), role: .cancel) {}
        }
        .alert(String(localized: "Add tags"), isPresented: $showAddTags) {
            TextField(String(localized: "comma,separated"), text: $tagDraft)
            Button(String(localized: "Add")) {
                let tags = parseTags(tagDraft); tagDraft = ""
                run { try await store.bulkAddTags(ids: selection, tags: tags) }
            }
            Button(String(localized: "Cancel"), role: .cancel) { tagDraft = "" }
        }
        .alert(String(localized: "Remove tags"), isPresented: $showRemoveTags) {
            TextField(String(localized: "comma,separated"), text: $tagDraft)
            Button(String(localized: "Remove")) {
                let tags = parseTags(tagDraft); tagDraft = ""
                run { try await store.bulkRemoveTags(ids: selection, tags: tags) }
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
                                showSetDue = false
                                run { try await store.bulkSetDue(ids: selection, to: dueDraft) }
                            }
                        }
                        ToolbarItem(placement: .cancellationAction) {
                            Button(String(localized: "Cancel")) { showSetDue = false }
                        }
                    }
            }
            .presentationDetents([.medium])
        }
    }

    private func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",").map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: " #")).lowercased()
        }.filter { !$0.isEmpty }
    }
    private func run(_ op: @escaping () async throws -> Void) {
        _Concurrency.Task { @MainActor in
            try? await op()
            selection.removeAll()
        }
    }
}
