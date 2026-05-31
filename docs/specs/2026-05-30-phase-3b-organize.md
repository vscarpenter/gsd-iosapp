# Phase 3b — Organize (Design Spec)

> **Date:** 2026-05-30 · **Status:** approved-by-delegation (user delegated autonomous execution; no user-review gate). Basis for the implementation plan.

## 1. Purpose & scope

Second slice of Phase 3. Adds the **organization** layer on top of 3a's filtering foundation: persisted **custom smart views** (+ pinning + criteria editor), **archive** (+ auto-archive), **search + ⌘K command palette**, and **bulk multi-select**. Builds directly on 3a (`FilterCriteria`/`TaskFilter`, `BuiltInSmartViews`, `TaskStore.tasks(matching:)`, the nav shell, `TaskListRow`).

**Out of scope (deferred):** sync of archive/smart-view changes (Phase 5 — archive/CRUD transitions will enqueue sync ops then; 3b is local-only), notifications (Phase 4), analytics/import-export/onboarding/full-Settings (3c).

## 2. Builds on (Phases 0–3a, on `main` at `phase-3a-filtering-navigation`)
- `GSDModel`: `Task`, `Subtask`, `Quadrant`, `RecurrenceType`, `DependencyGraph`, **`FilterCriteria`** (§5.9 bundle), **`TaskFilter.apply(_:to:now:calendar:)`**, **`SmartView`** (id/name/icon/criteria/isBuiltIn), **`BuiltInSmartViews.all`** (9 constants).
- `GSDStore`: `AppDatabase` (versioned `DatabaseMigrator`; `registerV1` = tasks table), `TaskRepository`/`GRDBTaskRepository`, `TaskRecord`, `GSDJSON`, `StoreLocation` (App-Group), `TaskStore` (`@MainActor @Observable`; `tasks`, injected `clock`/`calendar`/`newID`, `tasks(in:showCompleted:)`, `tasks(matching:)`, mutations).
- App: `ContentView` (iPhone `TabView` Matrix·Browse; iPad `NavigationSplitView` sidebar Matrix + Smart Views → detail), `SmartViewListView`/`SmartViewRow`, `FilteredTaskListView`, `TaskListRow`, `MatrixView`/`MatrixGridView`/`QuadrantSection`/`QuadrantCell`, `TaskActions`, `TaskEditorView`, `EditorRequest`, `QuadrantStyle`, `ConfettiView`.

## 3. Scope calls (decided autonomously; documented)
- **Custom smart views persist in a GRDB `smartViews` table** (new `v2` migration + `SmartViewRecord` + a `SmartViewRepository`); the 9 built-ins stay in-code constants (read-only). Browse/sidebar show **pinned first, then built-ins, then custom**.
- **Pinning + ArchiveSettings live in App-Group `UserDefaults`** (small UI/config state, matching the localStorage→UserDefaults note), NOT GRDB tables: `pinnedSmartViewIds: [String]` (ordered, max 5) and `archiveAutoEnabled: Bool` + `archiveAfterDays: Int` (30/60/90). Keeps 3b's migrations to just the two data tables.
- **`archivedTasks` is a separate GRDB table** (new `v3` migration), same columns as `tasks` plus `archivedAt: Date`. An `ArchiveRepository` owns archive/restore/delete/fetchAll/observe.
- **Auto-archive is pure logic** (`AutoArchive.tasksToArchive(_:afterDays:now:calendar:)` in `GSDModel`) run on launch (and re-run when settings change); no in-app timer.
- **Criteria editor** exposes: quadrants (multi-select), status (segmented), tags (token field), due predicates (toggles: overdue / dueToday / dueThisWeek / noDueDate), `dueDateRange` (optional start/end DatePickers), recurrence (multi-select), readyToWork (toggle), searchQuery (text). Built-ins are not editable.
- **Command palette (⌘K)**: a single overlay (sheet) with a search field and sectioned results — **Tasks** (open editor), **Smart Views** (open filtered list), **Actions** (New task, Toggle show-completed, Toggle theme), **Navigation** (Matrix, Browse, Archive). Match = case-insensitive substring (simple, not fuzzy-ranked — YAGNI). Invoked by ⌘K (hardware keyboard) and a toolbar magnifying-glass button (touch).
- **Search**: `.searchable` on the Browse filtered lists and Archive, feeding `FilterCriteria.searchQuery` (already implemented in 3a) via `TaskFilter`. No separate full-screen search surface beyond the palette.
- **Bulk multi-select**: SwiftUI `EditMode` selection on the matrix sections + filtered lists + archive; a bottom toolbar with Complete, Move to quadrant, Add tags, Remove tags, Set due date, Delete (destructive → confirm). Per-task validation; each op goes through the store.
- **Sync deferral**: archive/CRUD/bulk mutations stamp `updatedAt` and persist locally; the Phase-5 sync-enqueue is a documented TODO, not implemented.

## 4. Feature groups (→ plan groups)

### Group A — Smart-view persistence + CRUD + pinning (GSDModel/GSDStore + Browse/sidebar wiring)
- `SmartViewRecord` (GRDB) + `registerV2` migration (`smartViews` table: id, name, icon, criteria JSON, isBuiltIn=false, createdAt, updatedAt). `FilterCriteria` gains `Codable` for JSON storage.
- `SmartViewRepository` (`GRDBSmartViewRepository`): upsert/fetchAll/delete/observeAll. `TaskStore` (or a new `@Observable SmartViewStore`) exposes `customViews`, `allViews` (built-ins + custom), `createView`/`updateView`/`deleteView`, and pinning (`pinnedViews`, `pin`/`unpin`/`reorderPins`) backed by UserDefaults.
- Wire custom + pinned views into `SmartViewListView` (Browse) and the iPad sidebar (pinned section first).

### Group B — Criteria editor (custom view create/edit) — App
- `SmartViewEditorView`: form binding a `FilterCriteria` + name + icon; create + edit; delete for custom. Reached from a "+" in Browse / sidebar and an Edit affordance on custom rows. Save validates (non-empty name; ≤ limits). Built-ins read-only.

### Group C — Archive (GSDModel + GSDStore + App)
- `AutoArchive.tasksToArchive` (pure). `ArchivedTaskRecord` + `registerV3` (`archivedTasks` table). `ArchiveRepository`. `ArchiveStore` (or `TaskStore` methods): `archive(_:)`/`restore(_:)`/`deletePermanently(_:)`/`archivedTasks`/`runAutoArchiveSweep()`. `ArchiveSettings` in UserDefaults.
- `ArchiveListView` (read-only dimmed cards; swipe Restore / Delete; undo). Archive entry: iPad sidebar item; iPhone — a Browse row or a Settings entry (decide at plan: Browse row "Archive"). Auto-archive sweep on launch (in `GSDApp.task`).

### Group D — Search + Command Palette — App
- `.searchable` on `FilteredTaskListView` + `ArchiveListView` (binds `searchQuery`).
- `CommandPaletteView` (sheet): search field + sectioned results (Tasks/Smart Views/Actions/Navigation); ⌘K `.keyboardShortcut` + toolbar button; selecting a result performs the action (open editor, open view, run action, navigate).

### Group E — Bulk multi-select — App
- `EditButton`/`EditMode` + `@State selection: Set<String>` on the matrix + filtered lists + archive. A `BulkActionBar` (bottom toolbar) with the 6 ops; `TaskStore` bulk methods (`bulkComplete`/`bulkMove`/`bulkAddTags`/`bulkRemoveTags`/`bulkSetDue`/`bulkDelete`) — each iterates, validates, stamps `updatedAt`. Delete confirms.

## 5. Testing
- **GSDModel/GSDStore (`swift test`):** `FilterCriteria` Codable round-trip; `AutoArchive.tasksToArchive` (boundary: exactly-N-days, completed-only, disabled); `SmartViewRepository` CRUD + observe; `ArchiveRepository` archive/restore/delete + `archivedTasks` isolation from `tasks`; pinning persistence; bulk store methods (each op + validation); migrations v2/v3 apply cleanly on a fresh + existing DB.
- **App (`xcodebuild` + simctl smoke):** all surfaces build iPhone + iPad; launch + screenshot Browse (custom/pinned), the criteria editor, Archive, the palette, and a bulk-select state.

## 6. Acceptance criteria (A20–A27)
- **A20** Custom smart views: create/edit/delete persist (GRDB), survive relaunch; built-ins read-only.
- **A21** Pinning: pin up to 5 (ordered), surface first; persists (UserDefaults).
- **A22** Criteria editor: every editable §5.9 field round-trips through save; produces a view whose results match `TaskFilter`.
- **A23** Archive: archive moves a completed task to `archivedTasks` (removed from active); restore returns it; permanent delete removes it; archived tasks excluded from the matrix/smart views.
- **A24** Auto-archive: with auto on + archiveAfterDays N, completed tasks older than N days archive on sweep; off → none; boundary correct.
- **A25** Search: `.searchable` filters lists via `searchQuery` across title/description/tags/subtask-titles.
- **A26** Command palette: ⌘K opens it; Tasks/Smart Views/Actions/Navigation results work.
- **A27** Bulk: multi-select + each of the 6 bulk ops applies per-task (validated, `updatedAt` stamped); delete confirms.
- **Coverage:** `swift test` green sub-second for all new logic; both simulators build + launch (smoke).

## 7. Conventions (carried)
`GSDModel` zero-dep (Foundation only); `GSDStore` GRDB but no SwiftUI; inject time; `_Concurrency.Task` (never bare `Task {}`); `String(localized:)` for copy; ≥44pt + VoiceOver labels + Dynamic Type; Swift Testing for logic, `xcodebuild`+simctl for UI; one commit per task; compile-probe risky recalled APIs in `/tmp` before baking into the plan (candidates: GRDB `registerV2/V3` migration on an existing DB; `FilterCriteria` `Codable` for JSON column; `.searchable` + `.keyboardShortcut("k", modifiers: .command)`; `EditMode`/`List(selection:)` multi-select + a bottom `.toolbar` action bar).
