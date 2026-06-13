import SwiftUI
import GSDModel
import GSDStore

/// The result the palette selected — `ContentView` performs the effect (it owns the
/// navigation + editor sheet). Keeps the palette a pure presenter.
enum PaletteResult {
    case openTask(Task)
    case openSmartView(String)     // smart-view id
    case newTask
    case toggleShowCompleted
    case toggleTheme
    case navigate(PaletteDestination)
}
enum PaletteDestination { case matrix, browse, archive, dashboard, settings }

/// A Browse-stack route. The list links are value-based so the palette can push either a
/// smart view or the Archive by appending to `PaletteController.browsePath` — a plain
/// `[String]` couldn't express Archive (advisor note), so this enum carries both.
enum BrowseRoute: Hashable {
    case view(String)   // smart-view id
    case archive
}

/// Shared, environment-injected coordinator so the magnifying-glass buttons (which live
/// inside each surface's own toolbar) and the hardware ⌘K can all toggle one palette, and
/// so the palette's selection handler — which lives at the root — can drive navigation
/// state that the individual surfaces would otherwise own privately.
@Observable
final class PaletteController {
    var showPalette = false
    /// Compact (iPhone) tab selection: 0 = Matrix, 1 = Browse, 2 = Dashboard.
    var compactTab = 0
    /// The Browse `NavigationStack` path (compact). Pushing here opens a smart view / Archive.
    var browsePath: [BrowseRoute] = []
    /// iPad sidebar selection, mirrored here so the palette handler can set it. Optional
    /// because `List(selection:)` single-selection requires an optional binding.
    var regularSelection: RegularItem? = .matrix
    /// One-shot quadrant focus request (⌘1–⌘4 / `gsd://quadrant/<q>`): the matrix view
    /// scrolls to the quadrant and clears it.
    var focusedQuadrant: Quadrant?
}

/// iPad sidebar selection. Shared so the palette handler can drive it; `RegularRootView`
/// binds its `List(selection:)` to `PaletteController.regularSelection`.
enum RegularItem: Hashable { case matrix, archive, dashboard, settings, smartView(String) }

/// ⌘K command palette: a search field + sectioned, substring-matched results across
/// Tasks / Smart Views / Actions / Navigation. Case-insensitive; not fuzzy (YAGNI).
struct CommandPaletteView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var onSelect: (PaletteResult) -> Void

    private var q: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    private func match(_ text: String) -> Bool { q.isEmpty || text.lowercased().contains(q) }

    private var taskResults: [Task] {
        guard !q.isEmpty else { return [] }
        return store.tasks.filter { match($0.title) || match($0.description) }.prefix(8).map { $0 }
    }
    private var viewResults: [SmartView] {
        store.allViews.filter { match($0.name) }.prefix(8).map { $0 }
    }
    private var actionResults: [(String, String, PaletteResult)] {
        [(String(localized: "New task"), "plus.circle", .newTask),
         (String(localized: "Toggle show completed"), "checkmark.circle", .toggleShowCompleted),
         (String(localized: "Toggle theme"), "circle.lefthalf.filled", .toggleTheme)]
            .filter { match($0.0) }
    }
    private var navResults: [(String, String, PaletteResult)] {
        [(String(localized: "Matrix"), "square.grid.2x2", .navigate(.matrix)),
         (String(localized: "Dashboard"), "chart.bar.xaxis", .navigate(.dashboard)),
         (String(localized: "Browse"), "line.3.horizontal.decrease.circle", .navigate(.browse)),
         (String(localized: "Archive"), "archivebox", .navigate(.archive)),
         (String(localized: "Settings"), "gearshape", .navigate(.settings))]
            .filter { match($0.0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !taskResults.isEmpty {
                    Section(String(localized: "Tasks")) {
                        ForEach(taskResults) { task in
                            paletteRow(task.title, icon: "doc.text", iconColor: Surface.ink2) {
                                pick(.openTask(task))
                            }
                        }
                    }
                }
                if !viewResults.isEmpty {
                    Section(String(localized: "Smart Views")) {
                        ForEach(viewResults) { view in
                            paletteRow(view.name, icon: view.icon,
                                       iconColor: SmartViewRow.identityColor(for: view.id)) {
                                pick(.openSmartView(view.id))
                            }
                        }
                    }
                }
                if !actionResults.isEmpty {
                    Section(String(localized: "Actions")) {
                        ForEach(actionResults, id: \.0) { label, icon, result in
                            paletteRow(label, icon: icon, iconColor: Surface.ink2) { pick(result) }
                        }
                    }
                }
                if !navResults.isEmpty {
                    Section(String(localized: "Navigation")) {
                        ForEach(navResults, id: \.0) { label, icon, result in
                            paletteRow(label, icon: icon, iconColor: Surface.ink2) { pick(result) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Surface.paper)
            .navigationTitle(String(localized: "Commands"))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: String(localized: "Search tasks, views, actions"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) { dismiss() }
                }
            }
        }
    }

    /// A palette result row: ink text with a graphite (or identity-accent) icon —
    /// the de-blue of the command list. `.plain` keeps the title ink, not tinted.
    private func paletteRow(_ title: String, icon: String, iconColor: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).foregroundStyle(iconColor).frame(width: 26)
                Text(title).foregroundStyle(Surface.ink)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(Surface.surface)
    }

    private func pick(_ result: PaletteResult) {
        onSelect(result)
        dismiss()
    }
}
