import SwiftUI
import GSDModel
import GSDStore

/// The trash: tasks deleted in the last `TrashRetention.days` days, recoverable until the
/// sweep takes them. Swipe to Restore (leading) or Delete permanently (trailing, confirmed),
/// mirroring the Archive screen's gestures so the two read as the same kind of surface.
///
/// Rows are read on appear rather than observed. The trash is a settings destination the
/// user visits deliberately, not something the matrix renders, so a live query would cost
/// more than it buys.
struct TrashListView: View {
    @Environment(TaskStore.self) private var store

    @State private var rows: [ArchivedTask] = []
    @State private var pendingDelete: ArchivedTask?
    @State private var showEmptyConfirm = false
    @State private var loadFailed = false

    private var now: Date { .now }

    var body: some View {
        Group {
            if loadFailed {
                EmptyStateView(icon: "exclamationmark.triangle",
                               title: String(localized: "Couldn’t open the trash."),
                               message: String(localized: "Close and reopen this screen to try again."))
            } else if rows.isEmpty {
                EmptyStateView(icon: "trash",
                               title: String(localized: "Trash is empty."),
                               message: String(localized: "Deleted tasks stay here for \(TrashRetention.days) days, then they’re gone."))
            } else {
                List {
                    Section {
                        ForEach(rows, id: \.task.id) { row in
                            trashRow(row)
                        }
                    } footer: {
                        Text(String(localized: "Tasks are removed permanently \(TrashRetention.days) days after you delete them."))
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Surface.paper)
        .navigationTitle(String(localized: "Trash"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            brandedNavigationTitle(String(localized: "Trash"))
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) { showEmptyConfirm = true } label: {
                        Text(String(localized: "Empty"))
                    }
                    .foregroundStyle(Surface.alert)
                }
            }
        }
        .task { await reload() }
        .confirmationDialog(
            String(localized: "Delete “\(pendingDelete?.task.title ?? "")” permanently?"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete Permanently"), role: .destructive) {
                if let row = pendingDelete { deleteForever(row) }
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(String(localized: "This can’t be undone."))
        }
        .confirmationDialog(
            String(localized: "Empty the trash?"),
            isPresented: $showEmptyConfirm,
            titleVisibility: .visible
        ) {
            Button(String(localized: "Delete \(rows.count) Tasks"), role: .destructive) { emptyTrash() }
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "Every task in the trash is removed permanently. This can’t be undone."))
        }
    }

    private func trashRow(_ row: ArchivedTask) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(row.task.title)
                .font(.body)
                .foregroundStyle(Surface.ink)
                .lineLimit(2)
            Text(remainingLabel(row))
                .font(.footnote)
                .foregroundStyle(isLastDay(row) ? Surface.alert : Surface.ink3)
        }
        .padding(.vertical, 2)
        .listRowBackground(Surface.surface)
        .listRowSeparatorTint(Surface.hairline)
        .swipeActions(edge: .leading) {
            Button { restore(row) } label: {
                Label(String(localized: "Restore"), systemImage: "arrow.uturn.backward")
            }
            .tint(Surface.tint)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = row } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
            .tint(Surface.alert)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(row.task.title), \(remainingLabel(row))"))
    }

    private func daysLeft(_ row: ArchivedTask) -> Int {
        TrashRetention.daysRemaining(deletedAt: row.stampedAt, now: now, calendar: .current)
    }
    private func isLastDay(_ row: ArchivedTask) -> Bool { daysLeft(row) <= 1 }

    private func remainingLabel(_ row: ArchivedTask) -> String {
        let left = daysLeft(row)
        if left <= 0 { return String(localized: "Removed today") }
        if left == 1 { return String(localized: "1 day left") }
        return String(localized: "\(left) days left")
    }

    private func reload() async {
        do {
            rows = try await store.trashedTasks()
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }

    private func restore(_ row: ArchivedTask) {
        _Concurrency.Task {
            try? await store.restoreFromTrash(id: row.task.id)
            await reload()
        }
    }
    private func deleteForever(_ row: ArchivedTask) {
        _Concurrency.Task {
            try? await store.deleteForever(id: row.task.id)
            await reload()
        }
    }
    private func emptyTrash() {
        _Concurrency.Task {
            _ = try? await store.emptyTrash()
            await reload()
        }
    }
}
