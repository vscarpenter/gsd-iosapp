# Phase 3c — Insights & Data (Design Spec)

> **Date:** 2026-05-31 · **Status:** approved-by-delegation (autonomous run; no user-review gate). Basis for the implementation plan.

## 1. Purpose & scope
Final slice of Phase 3. Adds the **analytics dashboard** (Swift Charts), **import/export + reset**, **onboarding/About**, and a **full Settings screen** (+ Settings tab/sidebar item). Builds on 3a/3b (`TaskStore`, `FilterCriteria`/`TaskFilter`, archive, `ArchiveSettings`, the nav shell).

**Out of scope (deferred):** sync-enqueue on import (Phase 5 — import mutations persist locally; the enqueue is a documented TODO); the **Notifications** Settings section (Phase 4) and **Cloud Sync** Settings section (Phase 5) — NOT built here (the project ships no control that does nothing); notifications/sync themselves (Phase 4/5).

## 2. Builds on (Phases 0–3b, on `main` at `phase-3b-organize`)
- `GSDModel`: `Task` (+ `completedAt`/`createdAt`/`dueDate`/`estimatedMinutes`/`timeSpent`/`timeEntries`/`tags`), `Quadrant` (CaseIterable, Q1→Q4), `TimeTracking` (`timeSpentMinutes`), `FilterCriteria`/`TaskFilter`, `IDGenerator`, `GSDJSON` is in GSDStore (so export/import JSON for the model uses Foundation `JSONEncoder`/`JSONDecoder` in GSDModel, OR reuse the store's codec — see scope calls).
- `GSDStore`: `TaskStore` (`tasks`, `clock`/`calendar`, mutations incl. bulk; `repository.fetchAll()`), `TaskRepository`/`GRDBTaskRepository`, `AppGroupDefaults`/`ArchiveSettings`, `ArchiveRepository`.
- App: `ContentView` (iPhone `TabView` Matrix·Browse; iPad `NavigationSplitView` sidebar Matrix·Archive·Smart Views), `GSDApp` (`@AppStorage("appTheme")`/`showCompleted`, `.task` launch hooks), `MatrixView`, `TaskCardView`, `EditorRequest`, `QuadrantStyle`, `CommandPaletteView` (Actions incl. Toggle theme/show-completed — the palette can navigate to Dashboard/Settings once they exist).

## 3. Scope calls (decided autonomously; documented)
- **Analytics is a PURE engine in `GSDModel`** (`AnalyticsEngine.compute(tasks:now:calendar:trendDays:) -> AnalyticsSummary`) producing every §6.15 metric; injected `now`/`calendar`; fully unit-tested. The dashboard UI (App, `import Charts`) is a pure render of `AnalyticsSummary` — no logic in the view.
- **Import/export logic is PURE** in `GSDModel`: `TaskExport` (Codable `{ tasks, exportedAt, version }`), `TaskImporter` (lenient decode ignoring unknown keys; `merge(imported:into:newID:)` → id-collision regen + remap of `dependencies`/`parentTaskId`; `replace` is trivial). Limits (`maxImportTasks = 10_000`, `maxImportBytes ≈ 10 MB`) enforced at the import boundary. Pure + tested. `TaskStore` gains `exportJSON() -> Data` and `importTasks(_:mode:) async throws`.
- **Lenient decode:** decode tasks tolerating missing/extra keys (e.g. legacy `vectorClock`) — use a permissive per-task decode that fills defaults and skips unknowns; a task that fails hard is skipped (counted), not fatal.
- **Reset flow:** type-"RESET"-to-confirm, with an "export first" prompt; preserves theme (`appTheme` AppStorage untouched). Clears `tasks` (+ optionally `archivedTasks`/`smartViews` — decide: clear ALL app data except theme).
- **Settings (3c) sections:** Appearance (theme picker + show-completed), Archive (auto-archive toggle + 30/60/90 + "Archive now" → reuses 3b `ArchiveSettings`/sweep), Data & Storage (Export / Import / Erase All), About (version, privacy summary, links, re-show onboarding). **Notifications + Cloud Sync sections are NOT built** (Phase 4/5).
- **Navigation:** add a **Dashboard** tab (iPhone) + sidebar item (iPad) and a **Settings** tab (iPhone) + sidebar item (iPad). iPhone TabView becomes Matrix · Browse · Dashboard · Settings (4 tabs). iPad sidebar gains Dashboard + Settings items.
- **Onboarding:** first-run skippable flow gated by an `@AppStorage("hasOnboarded")` flag (App-Group); re-showable from Settings → About.
- **Export/Import UI:** `ShareLink` for export (`.json` via a `FileDocument` or a temp file URL); `.fileImporter` for import; both feed the pure `TaskStore` methods.

## 4. Feature groups (→ plan groups)
- **A — AnalyticsEngine (GSDModel, swift test):** `AnalyticsSummary` struct + `AnalyticsEngine.compute(...)` covering all §6.15 metrics (counts, completion rate, streaks + last-7-days, quadrant distribution + per-quadrant completion, tag stats, deadline counts + upcoming, completion trend 7/30/90, time-tracking summary). Boundary-heavy date math (streaks, today/week/month, trend buckets) — PROBE the streak + bucket logic.
- **B — Analytics Dashboard UI (App, Swift Charts, build+smoke):** `DashboardView` — stat-card grid, completion-trend line chart (7/30/90 segmented), quadrant donut/bar, top-tags bar, time-by-quadrant chart, upcoming-deadlines list (tap → editor), overdue banner, empty state. Dashboard nav entry (tab + sidebar).
- **C — Import/Export pure logic + store (GSDModel/GSDStore, swift test):** `TaskExport`/`TaskImporter` (merge id-remap, replace, lenient decode, limits) + `TaskStore.exportJSON()`/`importTasks(_:mode:)`. PROBE the merge id-remap + reference-remap.
- **D — Import/Export + Reset UI (App, build+smoke):** Settings → Data & Storage: `ShareLink` export, `.fileImporter` import (Replace/Merge picker), Erase-All (type "RESET" + export-first prompt).
- **E — Onboarding/About + Settings (App, build+smoke):** `OnboardingView` (first-run, skippable, paged), `SettingsView` (Appearance/Archive/Data & Storage/About), Settings nav entry (tab + sidebar), re-show-onboarding from About.

## 5. Testing
- **GSDModel/GSDStore (`swift test`):** `AnalyticsEngine` — every metric on a fixture set, streak boundaries (consecutive days, gap breaks streak, today-counts), trend buckets at 7/30/90, completion-rate div-by-zero (empty → 0), time-tracking summary; `TaskImporter` — merge with id collisions (regen + remap deps/parent), replace, lenient decode (unknown keys ignored, bad task skipped+counted), limit enforcement (>10k rejected); `TaskStore.exportJSON`/`importTasks` round-trip (export then import-replace → same set). Probe streak + merge-remap logic in `/tmp` first.
- **App (`xcodebuild` + simctl smoke):** all surfaces build iPhone + iPad; launch + screenshot the Dashboard (with seeded? — empty-state acceptable), Settings, and onboarding.

## 6. Acceptance criteria (A28–A34)
- **A28** AnalyticsEngine computes every §6.15 metric correctly (counts/rate/streaks/quadrant/tags/deadlines/trend/time) — unit-tested incl. boundaries.
- **A29** Dashboard renders all charts + stat cards from `AnalyticsSummary`; 7/30/90 trend toggle; overdue banner; empty state; upcoming-deadline tap opens the editor.
- **A30** Export produces `{tasks, exportedAt, version}` JSON; round-trips.
- **A31** Import: Replace clears+inserts; Merge regenerates colliding ids + remaps `dependencies`/`parentTaskId`; lenient decode ignores unknown keys; limits enforced.
- **A32** Reset: type-RESET-to-confirm, export-first prompt, theme preserved, clears app data.
- **A33** Settings: Appearance/Archive/Data & Storage/About sections work; Notifications/Cloud Sync NOT present (deferred); reachable via tab (iPhone) + sidebar (iPad).
- **A34** Onboarding: first-run skippable flow; re-showable from About; `hasOnboarded` flag gates it.
- **Coverage:** `swift test` green sub-second for all new logic; both sims build + launch (smoke).

## 7. Conventions (carried)
`GSDModel` zero-dep (Foundation only — `AnalyticsEngine`/`TaskExport`/`TaskImporter` use `Foundation`/`JSONEncoder`; NO GRDB/SwiftUI/Charts); `GSDStore` GRDB no SwiftUI; App may `import Charts`. Inject time. `_Concurrency.Task` (never bare `Task {}`). `String(localized:)` for copy. Store stamps `updatedAt`; import goes through the store. Swift Testing for logic; `xcodebuild`+simctl for UI. One commit per task. Compile-probe risky recalled APIs in `/tmp` before the plan (candidates: the streak/trend date-bucket math; the merge id-remap; `Swift Charts` API for line/bar/donut + the 7/30/90 toggle is "confirm at build"; `ShareLink`/`FileDocument`/`.fileImporter` are "confirm at build").
