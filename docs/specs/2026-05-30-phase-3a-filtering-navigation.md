# Phase 3a — Filtering & Navigation Foundation (Design Spec)

> **Date:** 2026-05-30 · **Status:** approved design; basis for the implementation plan (next: `superpowers:writing-plans`).

## 1. Purpose & scope

The first slice of Phase 3. It establishes the reusable **filtering engine** and the app's **navigation shell**, and makes the **9 built-in smart views** usable. **No new database tables.** This is the foundation the rest of Phase 3 builds on.

**Phase 3 decomposition (approved):**
- **3a — Foundation (this spec):** FilterCriteria pipeline, the 9 built-in smart views (in-code constants), the TabView/sidebar navigation shell, filtered-list surfaces.
- **3b — Organize:** archive (+ auto-archive, `archivedTasks` table), custom smart-view CRUD + criteria editor + pinning (`smartViews` table, `AppPreferences`), bulk multi-select, search + ⌘K command palette.
- **3c — Insights & Data:** analytics dashboard (Swift Charts), import/export + reset, onboarding/About, the full Settings screen.

## 2. Builds on (Phases 0–2, on `main` at `phase-2-task-depth`)

- **GSDModel:** `Task` (incl. `dueDate`, `recurrence`, `tags`, `subtasks`, `completed`, `completedAt`, `createdAt`, `dependencies`), `Subtask` (`.title`, `.completed`), `Quadrant` (`String` enum, `init(urgent:important:)`, `CaseIterable`, canonical Q1→Q4 order, `Hashable`), `RecurrenceType` (`none`/`daily`/`weekly`/`monthly`, `CaseIterable`), `DependencyGraph` (`uncompletedBlockers(of:)`, `readyTasks()`, …).
- **GSDStore:** `TaskStore` (`@MainActor @Observable`; `tasks`, injected `clock`/`calendar`/`newID`, `tasks(in:showCompleted:)`).
- **App:** adaptive `ContentView` (compact → `MatrixView`, regular → `MatrixGridView`), `TaskCardView`, `TaskActions`, `TaskEditorView` (presented as a sheet), `QuadrantStyle`. `showCompleted` is an `@AppStorage("showCompleted")` matrix-toolbar toggle; theme is `@AppStorage("appTheme")`.

> **Current navigation reality (verified):** there is **no Settings screen** and **no `TabView`/`NavigationSplitView` sidebar** yet. `ContentView` only switches `MatrixView`↔`MatrixGridView`. 3a genuinely introduces the navigation shell on both idioms.

## 3. Out of scope (deferred)

- **3b:** custom smart-view create/edit/delete, the criteria-editor UI, pinning + `AppPreferences`, the `smartViews` table; archive + `archivedTasks` table; ad-hoc matrix filter bar; the search field + ⌘K palette; bulk multi-select.
- **3c:** analytics dashboard, import/export + reset, onboarding/About, the full Settings screen (and therefore a **Settings tab**).
- Reminders/notifications (Phase 4); sync (Phase 5).

## 4. Data model (GSDModel, pure)

### 4.1 `FilterCriteria` (product spec §5.9)

A predicate bundle; **all present criteria are ANDed**. Default value constrains nothing (matches every task). A `Bool` flag of `false` means "do not constrain on this," **not** "must be false."

| Field | Type | Meaning |
|---|---|---|
| `quadrants` | `[Quadrant]` | include only these quadrants (empty = all) |
| `status` | `enum { all, active, completed }` | `active` = incomplete |
| `tags` | `[String]` | task must contain **all** listed tags |
| `dueDateRange` | `{ start: Date?, end: Date? }` | inclusive bounds |
| `overdue` | `Bool` | active **and** `dueDate` < start-of-today |
| `dueToday` | `Bool` | active **and** `dueDate` is today |
| `dueThisWeek` | `Bool` | active **and** `dueDate` ∈ [start-of-today, +7 days) |
| `noDueDate` | `Bool` | has no `dueDate` |
| `recurrence` | `[RecurrenceType]` | include only these kinds (empty = all) |
| `recentlyAdded` | `Bool` | `createdAt` within last 7 days |
| `recentlyCompleted` | `Bool` | completed **and** `completedAt` within last 7 days |
| `readyToWork` | `Bool` | active **and** no uncompleted blocking dependency (§6.8) |
| `searchQuery` | `String` | case-insensitive substring over title, description, tags, **subtask titles**; empty = no constraint |

### 4.2 `SmartView`

Value type: `id: String`, `name: String`, `icon: String` (SF Symbol), `criteria: FilterCriteria`, `isBuiltIn: Bool`. **Not persisted in 3a** — there is no `smartViews` table. Built-ins are in-code constants.

### 4.3 `BuiltInSmartViews` — the 9 built-ins (read-only, stable IDs)

| # | id | Name | SF Symbol | Criteria |
|---|---|---|---|---|
| 1 | `today-focus` | Today's Focus | `target` | quadrants:[urgentImportant], status:active |
| 2 | `this-week` | This Week | `calendar` | status:active, dueThisWeek |
| 3 | `overdue` | Overdue Backlog | `exclamationmark.triangle` | status:active, overdue |
| 4 | `no-deadline` | No Deadline | `calendar.badge.minus` | status:active, noDueDate |
| 5 | `recently-added` | Recently Added | `sparkles` | status:active, recentlyAdded |
| 6 | `weeks-wins` | This Week's Wins | `trophy` | status:completed, recentlyCompleted |
| 7 | `all-completed` | All Completed | `checkmark.circle` | status:completed |
| 8 | `recurring` | Recurring Tasks | `repeat` | status:active, recurrence:[daily,weekly,monthly] |
| 9 | `ready-to-work` | Ready to Work | `bolt` | status:active, readyToWork |

(SF Symbol choices are a presentation detail, refinable during implementation.)

## 5. Filtering pipeline (GSDModel, pure, TDD)

`TaskFilter.apply(_ criteria: FilterCriteria, to tasks: [Task], now: Date, calendar: Calendar) -> [Task]`

- **Pure and total** (no `throw`); time injected (`now` + `calendar`) — no `Date()` / `Calendar.current` inside.
- Sequential **AND** of every present criterion.
- **`readyToWork` requires the full task set:** build `DependencyGraph(tasks: tasks)` internally and use `uncompletedBlockers`. Do **not** pre-narrow the set before resolving it — a blocker excluded by another criterion must still count as blocking.
- **Date predicates** use `calendar` (`startOfDay`, `isDate(_:inSameDayAs:)`, `date(byAdding:)`).
- **`searchQuery`:** lowercased substring over `title`, `description`, each tag, and each `subtask.title`.
- Build the **complete** pipeline (all §5.9 fields). `searchQuery` and `dueDateRange` are implemented and tested now but only *surfaced* by 3b (search) / the custom-view editor — the built-in views don't use them.
- **Result sort (3a scope-call):** if `criteria.status == .completed` → sort by `completedAt` descending (nil last); otherwise → by `dueDate` ascending (nil last), tie-broken by `createdAt` descending. Documented default; refinable in 3b.

## 6. Store (GSDStore)

`TaskStore.tasks(matching: FilterCriteria) -> [Task]` — delegates to `TaskFilter` using the store's injected `clock()` and `calendar`, over the observable `tasks`. Live (recomputes from the snapshot). Backs both the filtered lists and the Browse live counts.

## 7. Navigation & UI (App, build-verified via `xcodebuild`)

3a introduces the navigation shell; neither idiom has one today.

### 7.1 iPhone (compact) — `TabView`
`ContentView` (compact) → a `TabView` with **two** tabs:
- **Matrix** — the existing `MatrixView` (unchanged).
- **Browse** — `SmartViewListView`.

A **Settings tab is deferred to 3c** (when a Settings screen exists). `showCompleted` (matrix toolbar) and theme (`@AppStorage`) stay exactly where they are.

### 7.2 iPad (regular) — `NavigationSplitView`
`ContentView` (regular) → a `NavigationSplitView`:
- **Sidebar:** a "Matrix" item + a **"Smart Views"** section listing the 9 built-ins (each with a live count).
- **Content/detail:** Matrix selected → `MatrixGridView`; a smart view selected → `FilteredTaskListView`.
- Editor presentation is unchanged from Phase 1 (sheet); 3a does not convert it to an inspector.

### 7.3 `SmartViewListView` (Browse)
A `List` of the 9 built-ins (icon + name + live count via `store.tasks(matching:).count`). Tap → push `FilteredTaskListView`. Each row carries a VoiceOver label (e.g. "Today's Focus, 4 tasks").

### 7.4 `FilteredTaskListView`
A flat, cross-quadrant `List` of `store.tasks(matching: criteria)`, each rendered with `TaskCardView` and wired to `TaskActions` (swipe / context menu / tap-to-edit) exactly as the matrix rows are. Navigation title = the view's name. Graceful **empty state** ("No tasks match") when the result is empty. The Phase-2 `TimelineView` live-timer row treatment should be reused if practical; otherwise note it at plan time.

## 8. Decisions / scope-calls

- **Lean data layer** — no new tables in 3a; built-ins are in-code constants. *(approved)*
- **Complete pipeline now** — `searchQuery`/`dueDateRange` built + tested, surfaced in 3b. *(approved)*
- **TabView = Matrix + Browse only** (no Settings tab in 3a); iPad gains the sidebar. *(correction from the approved sketch — no Settings screen exists yet)*
- **Result sort rule** (§5) is a documented default, refinable in 3b.
- **Live counts recompute per render** (≤9 filter passes); acceptable at expected task counts — no caching (YAGNI; measure first).
- **Filtering is read-only/derived** — never mutates; the store remains the only mutation path.

## 9. Edge cases

- Empty criteria → all tasks.
- A `Bool` flag of `false` = no constraint (not "must be false").
- `overdue`/`dueToday`/`dueThisWeek` implicitly require active (incomplete), per §5.9.
- `readyToWork` resolved over the **full** set; a *completed* blocker does not block (`uncompletedBlockers`).
- `dueThisWeek` window is half-open: `[startOfToday, startOfToday + 7 days)`.
- `recentlyAdded`/`recentlyCompleted` = within the last 7 days of `now` (inclusive of today).
- `searchQuery` empty or whitespace-only → no constraint.
- Tasks with no `dueDate` are excluded from `overdue`/`dueToday`/`dueThisWeek`; included by `noDueDate`.

## 10. Acceptance criteria (A16–A19, continuing the project series)

- **A16 — Filtering pipeline.** Every §5.9 field filters correctly and criteria AND together; date predicates correct under a pinned `calendar`/`now` (half-open week window; start-of-day `overdue`); `readyToWork` resolved over the full set; `searchQuery` matches across title/description/tags/subtask-titles, case-insensitively. A test per criterion + combinations.
- **A17 — Built-in views.** Each of the 9 yields the spec-correct set on a fixture task set; IDs are stable; the displayed counts match.
- **A18 — Store.** `tasks(matching:)` returns the filtered set using the store's injected `clock`/`calendar`.
- **A19 — Navigation/UI.** iPhone `TabView` (Matrix, Browse) and iPad `NavigationSplitView` sidebar build clean on both simulators; Browse lists the views with live counts; selecting a view shows the filtered list reusing `TaskCardView` + `TaskActions`; empty state present; VoiceOver labels on view rows; Dynamic Type respected. *(On-device VoiceOver/behavioral confirmation folds into the still-pending manual a11y pass.)*
- **Coverage.** Full `swift test` green, sub-second; both iPhone + iPad simulators build.

## 11. Conventions (carried from Phases 0–2)

GSDModel stays **zero-dependency** (Foundation only; never `import GRDB`/`SwiftUI`); **inject time** (`Calendar`/`now`); use **`_Concurrency.Task`** for concurrency (never bare `Task {}` in files importing `GSDModel`); **`String(localized:)`** for all user-facing copy (interpolated forms allowed); **≥44pt** targets, VoiceOver labels, Dynamic Type; **Swift Testing** for logic, **`xcodebuild`** for UI; **one commit per task**. **Compile-probe risky recalled APIs in `/tmp`** before baking them into the plan — candidates here: an adaptive root that hosts a `TabView` on compact width and a `NavigationSplitView` on regular width; and a `NavigationSplitView` sidebar-selection binding driving the detail column.
