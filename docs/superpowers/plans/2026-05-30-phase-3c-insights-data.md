# Phase 3c — Insights & Data Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the final Phase-3 slice — a pure **AnalyticsEngine** + a Swift Charts **Dashboard**, pure **import/export** logic + store methods, **Import/Export/Reset** UI, **onboarding**, and a full **Settings** screen — plus the cross-cutting nav change (iPhone TabView gains Dashboard + Settings; iPad sidebar gains Dashboard + Settings).

**Architecture:** Correctness-critical analytics + import/export land as pure, dependency-free units in `GSDModel` (`AnalyticsEngine`/`AnalyticsSummary`, `TaskExport`/`TaskImporter`), red→green→refactor'd with Swift Testing and an injected `Calendar`/`now`/`newID` (streak/trend date math + the merge id-remap are probe-verified). The single `@MainActor @Observable TaskStore` grows `exportJSON() -> Data`, `importTasks(_:mode:) async throws`, a `replaceAll(_:)` repository path (single-transaction, avoids the O(n²) per-id delete scrub), and an `eraseAllData()` reset. The app gains a `DashboardView` (a pure render of `AnalyticsSummary`, `import Charts`), a Settings screen (Appearance/Archive/Data & Storage/About), a Data & Storage sub-view (ShareLink export / `.fileImporter` import / type-RESET reset), and an `OnboardingView` gated by `@AppStorage("hasOnboarded")`.

**Tech Stack:** Swift 6 (toolchain Apple Swift 6.3.2), SwiftUI (Observation, `TabView`, `NavigationSplitView`, `ShareLink`, `FileDocument`, `.fileImporter`), **Swift Charts** (`Chart`/`LineMark`/`BarMark`/`SectorMark`), GSDKit (`GSDModel` zero-deps + `GSDStore` over GRDB), Swift Testing (`@Test`/`#expect`) for logic, `xcodebuild` for the app.

**Builds on (Phases 0–3b, committed on `main`):**
- `GSDModel` (zero-dep, Foundation only): `Task` (full §5.1 field set incl. `completedAt`/`createdAt`/`dueDate`/`estimatedMinutes`/`timeSpent`/`timeEntries`/`tags`/`dependencies`/`parentTaskId`; the short init `Task(id:title:urgent:important:createdAt:updatedAt:)` compiles with defaults for everything else), `Subtask`, `Quadrant` (`String` enum, `CaseIterable`, Q1→Q4, `.title`, `init(urgent:important:)`), `RecurrenceType` (`String` enum, `CaseIterable` `none`/`daily`/`weekly`/`monthly`), `TimeEntry` (`startedAt`/`endedAt?`), `TimeTracking` (`timeSpentMinutes(_:)`, `format(minutes:)`), `FilterCriteria`/`TaskFilter`, `SmartView`/`BuiltInSmartViews`, `IDGenerator` (`Size.task = 21`), `DependencyGraph`.
- `GSDStore` (GRDB, no SwiftUI): `AppDatabase` (`writer`, `inMemory()`, `live()`), `TaskRepository`/`GRDBTaskRepository` (`upsert`/`fetchAll`/`fetch(id:)`/`delete(id:)` — **`delete` does an O(n) dependency-scrub scan** — `observeAll()`), `TaskRecord` (`init(_:)`/`toDomain()`), `GSDJSON` (**internal** ms-truncating ISO-8601 codec), `StoreLocation.appGroupID = "group.dev.vinny.gsd"`, `AppGroupDefaults` (`shared`, `Key`), `ArchiveSettings`, `SmartViewRepository`/`ArchiveRepository`, `TaskStore` (`@MainActor @Observable`; `tasks`/`customViews`/`archivedTasks`, injected `clock`/`calendar`/`newID`/`defaults`/repositories, `start()`, mutations, `tasks(matching:)`, smart-view CRUD + pinning, archive, `archiveSettings`, bulk ops).
- App: `ContentView` (iPhone `TabView` with `PaletteController.compactTab` selection: tag 0 = Matrix, tag 1 = Browse; iPad `RegularRootView` `NavigationSplitView` whose sidebar binds `List(selection: $palette.regularSelection)` to the `RegularItem` enum `{ matrix, archive, smartView(String) }`; the ⌘K palette + editor sheets live at the root), `GSDApp` (`@State store`, `@AppStorage("appTheme", store: .shared)`, `.task { store.start(); try? await store.runAutoArchiveSweep() }`), `PaletteController` (`@Observable`: `showPalette`/`compactTab`/`browsePath: [BrowseRoute]`/`regularSelection: RegularItem?`), `CommandPaletteView`/`PaletteResult`/`PaletteDestination`/`BrowseRoute`, `MatrixView`/`MatrixGridView` (toolbar via `paletteButton(_:)` + `showCompletedToggle(_:)`; `EditorRequest` + `.sheet(item:)`), `SmartViewListView`/`SmartViewRow`, `FilteredTaskListView`, `TaskEditorView(request:)`/`EditorRequest`, `AppTheme` (`system`/`light`/`dark`, `.label`, `.colorScheme`, `Font.serif(_:)`), `UserDefaults.shared` (App-Group, `App/Store/AppPreferences.swift`).

**Reference:** design spec `docs/specs/2026-05-30-phase-3c-insights-data.md`; exemplars `docs/superpowers/plans/2026-05-30-phase-3a-filtering-navigation.md`, `…-phase-3b-organize.md`; product spec `2026-05-30-native-ios-app-design.md` (§6.15 analytics).

---

## Architecture conventions locked by this plan (read first)

1. **`GSDModel` stays zero-dependency.** `AnalyticsEngine`/`AnalyticsSummary`, `TaskExport`/`TaskImporter` link only `Foundation`. **NO GRDB, NO SwiftUI, NO Charts.** `String(localized:)` is Foundation-provided (precedent: `TimeTracking.format`).
2. **`GSDModel.Task` shadows Swift Concurrency's `Task`.** Use bare `Task` only as the domain type; in app/test concurrency use `_Concurrency.Task { }` (never bare `Task { }`).
3. **Inject time.** `AnalyticsEngine.compute(tasks:now:calendar:trendDays:)` takes `now`/`calendar`; the store passes its injected `clock()`/`calendar`. Tests pin a fixed UTC gregorian calendar + fixed `now`. **The streak/trend math is PROBE-VERIFIED** (see Probe Results below).
4. **Analytics is a pure value-in/value-out engine; the Dashboard is a pure render.** `DashboardView` holds NO logic — it reads `store.analytics(trendDays:)` (a thin wrapper over `AnalyticsEngine`) and renders. The 7/30/90 `Picker` only changes the `trendDays` argument.
5. **Export codec is self-owned in GSDModel.** `GSDJSON` is `internal` to `GSDStore` and GSDModel is the *lower* module — it cannot import it. `TaskExport` therefore defines its **own** fractional-seconds ISO-8601 `JSONEncoder`/`JSONDecoder` mirroring `GSDJSON`'s strategy (`.withInternetDateTime, .withFractionalSeconds`), so an export round-trips through the store's date coding without precision drift. **Precedent:** 3b's `FilterCriteriaCodableTests` builds the identical local formatter. This is the round-trip-fidelity decision the spec flagged — decided: **match GSDJSON's strategy**.
6. **Import goes through the store** (stamps `updatedAt = clock()` per the §3.3 invariant). Replace clears via a single-transaction `replaceAll(_:)` on the repository (NOT per-id `delete`, whose dependency-scrub scan makes a 10k clear O(n²)); Merge upserts the remapped tasks one-by-one (the normal upsert path is fine). **Sync-enqueue on import is a Phase-5 documented TODO** (a `// NOTE (Phase 5)` comment, no behavior).
7. **Reset preserves theme.** `eraseAllData()` clears tasks + archived + custom smart views + pinning + archive settings, but **never touches `appTheme`** (App `@AppStorage`, a different key the store doesn't own) or `hasOnboarded`.
8. **Limits at the import boundary.** `TaskImporter.maxImportTasks = 10_000`, `maxImportBytes = 10 * 1024 * 1024`. Byte limit is enforced on the raw `Data` before decode; task-count limit after decode. Exceeding either throws `ImportError`.
9. **Lenient decode lives in `Task.init(from:)` (PROBE-VERIFIED).** Swift's *synthesized* `Codable` ignores unknown keys but **throws on any absent non-optional key** — and `Task` has many non-optional fields with member-init defaults (`tags`/`subtasks`/`dependencies`/`recurrence`/`completed`/`description`/`notificationEnabled`/`notificationSent`/`timeEntries`). So a legacy/web export omitting those would be skipped, breaking the spec's "fills defaults" requirement (and the web/PocketBase interop the codebase targets). Fix: give `Task` a **custom `init(from:)`** that `decode`s only the 6 truly-required fields (`id`/`title`/`urgent`/`important`/`createdAt`/`updatedAt` — the ones with no member default) and `decodeIfPresent ?? <member default>` for every other field; leave `encode(to:)` synthesized. The importer's `LenientTask` wrapper then `try? Task(from:)` → a task missing a *required* field or carrying a wrong-typed value is **skipped and counted** (`ImportResult.skipped`); unknown keys (e.g. legacy `vectorClock`) are ignored. Verified in `/tmp/p3c-probe/task_lenient.swift` (9/9): legacy task with only required keys decodes with defaults, wrong-typed/required-missing → nil, computed `quadrant` excluded from `CodingKeys`, encode round-trips. **No other code path decodes `Task` from JSON** (`TaskRecord.toDomain()` builds it from DB columns via the member init), so this is safe — confirmed by grep.
10. **Accessibility + localization (carried):** Dynamic Type, VoiceOver labels, `String(localized:)` for ALL UI copy, ≥44pt targets.
11. **SwiftUI/Charts APIs are "confirm at build."** Swift Charts `Chart`/`LineMark`/`BarMark`/`SectorMark` + the 7/30/90 `Picker`, `ShareLink`/`FileDocument`/`.fileImporter`, the 4-tab `TabView` + sidebar additions can't be `/tmp`-probed; they are verified via `xcodebuild` on both simulators (flag at build if they don't compile as written).

---

## Scope calls (from the approved spec; do not relitigate)

- **AnalyticsEngine is pure in GSDModel** producing every §6.15 metric in one `AnalyticsSummary`; injected `now`/`calendar`/`trendDays`. The Dashboard is a pure render.
- **today-with-zero streak rule = LENIENT** (probe-pinned): today with 0 completions → the active streak counts backward starting from yesterday (it does NOT reset to 0). If yesterday is also 0, active = 0. Rationale: the convention for streak features; avoids "streak resets every morning."
- **Trend buckets** half-open `[startOfDay(day), +1day)`, exactly N buckets anchored at `startOfDay(now)`, index 0 = oldest (N−1 days ago), index N−1 = today; created keyed by `createdAt`, completed by `completedAt`; anything outside the window dropped. Identical to 3a's date convention.
- **Export** = `TaskExport { tasks: [Task], exportedAt: Date, version: Int }` (version 1), encoded with the GSDModel-local fractional-seconds codec. Round-trips through the store.
- **Import modes:** `replace` clears all active tasks then inserts the imported set (single transaction); `merge` regenerates colliding ids + remaps `dependencies`/`parentTaskId`, then upserts. Both go through the store.
- **Reset** = type-"RESET"-to-confirm with an "Export first" prompt; preserves `appTheme` + `hasOnboarded`; clears tasks + archived + custom views + pinning + archive settings.
- **Settings sections:** Appearance (theme picker + show-completed), Archive (auto-archive toggle + 30/60/90 + "Archive now"), Data & Storage (Export / Import / Erase All), About (version, privacy summary, links, re-show onboarding). **Notifications + Cloud Sync sections are NOT built** (Phase 4/5 — the project ships no control that does nothing).
- **Navigation:** iPhone TabView becomes Matrix · Browse · Dashboard · Settings (4 tabs); iPad sidebar gains Dashboard + Settings items. The Dashboard tab/sidebar entry lands in **Group B** (so the tab never points at an unbuilt screen); the Settings entry lands in **Group E**.
- **Onboarding:** first-run, skippable, paged; gated by `@AppStorage("hasOnboarded", store: .shared)`; re-showable from Settings → About.

---

## Probe Results (run before this plan shipped; folded in)

Three standalone Swift probes ran against the installed toolchain (Apple Swift 6.3.2) in `/tmp/p3c-probe/`, each with a fixed UTC gregorian calendar and fixed `now = 2026-06-15 09:00 UTC`:

- **`streak.swift` — 10/10 PASS.** Pinned rules: a **completion day** = `startOfDay(completedAt)`; **active streak** counts consecutive completion days ending at today, or — when **today has 0 completions** — counts backward starting from **yesterday** (LENIENT rule; does not reset to 0); active = 0 only when neither today nor yesterday has a completion. A **gap day breaks** the active streak. **Longest streak** = the max run of consecutive completion days over all history (0 when none). Multiple completions on one day count **once**. **last-7** = a 7-element `[Bool]`, index 0 = 6-days-ago, index 6 = today (chronological), each `true` iff that day has ≥1 completion.
- **`trend.swift` — 13/13 PASS.** Pinned rules: N buckets, index 0 = oldest (N−1 days before today), index N−1 = today; each bucket half-open `[startOfDay, +1day)`; `startOfDay(today)` counts in today's bucket (inclusive start), the following midnight is excluded; created keyed by `createdAt`, completed by `completedAt`, independently; a task created/completed **outside** the window is dropped. Verified at N ∈ {7, 30, 90} (7d first bucket = 6/9; 30d first = 5/17; 90 buckets for N=90).
- **`merge.swift` — 12/12 PASS.** Pinned rules (two-phase): **Phase 1** builds the complete `oldID→newID` map across ALL imported tasks whose id ∈ existing-store-ids; a regenerated id is retried until it collides with neither existing ids, other imported ids, nor already-assigned new ids. **Phase 2** rewrites each imported task's `id`, every `dependencies` entry, and `parentTaskId` through the map. Verified: B-listed-before-A still remaps B's dependency to A's new id (forward reference); `parentTaskId` remaps; non-colliding ids/refs untouched; a dangling ref (to a non-imported, non-existing id) is preserved as-is; a regenerated id skips an id that is itself an imported id.

- **`task_lenient.swift` — 9/9 PASS.** A follow-up probe (run after the first three, when the `LenientTask` design surfaced a synthesized-`Codable` trap) confirmed the **custom `Task.init(from:)`** approach (Task C0): a legacy task with only the 6 required keys decodes with all defaulted fields filled (`tags == []`, `notificationEnabled == true`, etc.); a missing-required-field or wrong-typed task → throws (→ skipped); the explicit `CodingKeys` excludes the computed `quadrant` so synthesized `encode(to:)` omits it; encode→decode round-trips equal. This pinned the fix for convention 9 (synthesized `Codable` throws on absent non-optional keys, which `Task` has many of).

> The Swift Charts API (`Chart`/`LineMark`/`BarMark`/`SectorMark` + 7/30/90 `Picker`), `ShareLink`/`FileDocument`/`.fileImporter`, and the 4-tab `TabView`/sidebar additions are **confirm-at-build** (SwiftUI/Charts can't be `/tmp`-probed) — verified by `xcodebuild` on both simulators in Groups B, D, E.

---

## File Structure

```
GSDKit/Sources/GSDModel/
├─ AnalyticsSummary.swift        # NEW: the computed metric bundle (pure value type)
├─ AnalyticsEngine.swift         # NEW: compute(tasks:now:calendar:trendDays:) -> AnalyticsSummary
├─ TaskExport.swift              # NEW: TaskExport Codable + local ISO-8601 codec + encode/decode
├─ TaskImporter.swift            # NEW: lenient decode + merge id-remap + replace + limits
└─ Task.swift                    # MODIFIED (C0): + custom lenient init(from:) + explicit CodingKeys

GSDKit/Tests/GSDModelTests/
├─ AnalyticsEngineTests.swift    # NEW: every metric + streak/trend boundaries + div-by-zero
├─ TaskExportTests.swift         # NEW: export shape + round-trip + codec
└─ TaskImporterTests.swift       # NEW: merge remap, replace, lenient decode, limits

GSDKit/Sources/GSDStore/
└─ TaskStore.swift               # MODIFIED: + analytics(trendDays:), exportJSON(), importTasks(_:mode:), eraseAllData()
GSDKit/Sources/GSDStore/TaskRepository.swift  # MODIFIED: + replaceAll(_:) on protocol + GRDBTaskRepository

GSDKit/Tests/GSDStoreTests/
├─ TaskRepositoryReplaceTests.swift  # NEW: replaceAll single-transaction clear+insert
├─ TaskStoreAnalyticsTests.swift     # NEW: analytics(trendDays:) over the live snapshot
└─ TaskStoreDataTests.swift          # NEW: exportJSON/importTasks round-trip + erase

App/
├─ ContentView.swift             # MODIFIED: 4-tab TabView (+Dashboard +Settings); iPad sidebar (+Dashboard +Settings); palette nav targets
├─ Palette/CommandPaletteView.swift  # MODIFIED: PaletteDestination/RegularItem +dashboard +settings; nav rows
├─ GSDApp.swift                  # MODIFIED: hasOnboarded gate → present OnboardingView
├─ Dashboard/
│  └─ DashboardView.swift        # NEW (Group B): stat cards + charts + deadlines list + empty state
├─ Settings/
│  ├─ SettingsView.swift         # NEW (Group E): Appearance/Archive/Data & Storage/About
│  └─ DataStorageView.swift      # NEW (Group D): ShareLink export, .fileImporter import, type-RESET reset
└─ Onboarding/
   └─ OnboardingView.swift       # NEW (Group E): first-run paged, skippable
```

---

## Group A — AnalyticsEngine + AnalyticsSummary (`GSDModel`, `swift test`, sub-second)

> Pure value-in/value-out with injected time. Build fully red→green before the Dashboard. Run from the package root: `cd GSDKit && swift test --filter <SuiteName>`. Maps **A28**.

### Task A1: `AnalyticsSummary` value type

**Files:** Create `GSDKit/Sources/GSDModel/AnalyticsSummary.swift`

The computed bundle the engine produces and the Dashboard renders. No logic — just the metric fields (§6.15). Lands first so A2's engine has a concrete return type.

- [ ] **Step 1: Write `AnalyticsSummary.swift`:**
```swift
import Foundation

/// Every dashboard metric (product spec §6.15), computed once by `AnalyticsEngine`.
/// Pure value type; the Dashboard is a render of this. Sendable so it crosses the
/// MainActor boundary from a background compute if ever needed.
public struct AnalyticsSummary: Equatable, Sendable {
    /// One day of the completion trend: created vs completed counts in `[startOfDay, +1day)`.
    public struct TrendPoint: Equatable, Sendable, Identifiable {
        public let date: Date          // startOfDay of the bucket
        public let created: Int
        public let completed: Int
        public var id: Date { date }
        public init(date: Date, created: Int, completed: Int) {
            self.date = date; self.created = created; self.completed = completed
        }
    }
    /// Per-quadrant counts. `total` = all tasks in the quadrant; `completed` ≤ `total`.
    public struct QuadrantStat: Equatable, Sendable, Identifiable {
        public let quadrant: Quadrant
        public let total: Int
        public let completed: Int
        public var id: Quadrant { quadrant }
        /// 0...1; 0 when the quadrant is empty.
        public var completionRate: Double { total == 0 ? 0 : Double(completed) / Double(total) }
        public init(quadrant: Quadrant, total: Int, completed: Int) {
            self.quadrant = quadrant; self.total = total; self.completed = completed
        }
    }
    /// Count of tasks carrying a given tag (active + completed).
    public struct TagStat: Equatable, Sendable, Identifiable {
        public let tag: String
        public let count: Int
        public var id: String { tag }
        public init(tag: String, count: Int) { self.tag = tag; self.count = count }
    }
    /// Total tracked minutes per quadrant (from `timeSpent`/`timeEntries`).
    public struct TimeByQuadrant: Equatable, Sendable, Identifiable {
        public let quadrant: Quadrant
        public let minutes: Int
        public var id: Quadrant { quadrant }
        public init(quadrant: Quadrant, minutes: Int) { self.quadrant = quadrant; self.minutes = minutes }
    }

    // Counts
    public let totalCount: Int
    public let activeCount: Int
    public let completedCount: Int
    /// Completed / total, 0...1; 0 when there are no tasks (div-by-zero guard).
    public let completionRate: Double

    // Streaks
    public let activeStreak: Int
    public let longestStreak: Int
    /// 7 entries, index 0 = 6-days-ago, index 6 = today; `true` iff that day had ≥1 completion.
    public let lastSevenDays: [Bool]

    // Distributions
    public let quadrantStats: [QuadrantStat]      // always 4, Q1→Q4 order
    public let topTags: [TagStat]                 // desc by count, capped (see engine)

    // Deadlines
    public let overdueCount: Int
    public let dueTodayCount: Int
    public let dueThisWeekCount: Int
    /// Active, dated, not-overdue tasks sorted by `dueDate` asc, capped (see engine).
    public let upcomingDeadlines: [Task]

    // Trend (length == requested trendDays)
    public let trend: [TrendPoint]

    // Time tracking
    public let totalTrackedMinutes: Int
    public let timeByQuadrant: [TimeByQuadrant]   // always 4, Q1→Q4 order

    public init(totalCount: Int, activeCount: Int, completedCount: Int, completionRate: Double,
                activeStreak: Int, longestStreak: Int, lastSevenDays: [Bool],
                quadrantStats: [QuadrantStat], topTags: [TagStat],
                overdueCount: Int, dueTodayCount: Int, dueThisWeekCount: Int, upcomingDeadlines: [Task],
                trend: [TrendPoint], totalTrackedMinutes: Int, timeByQuadrant: [TimeByQuadrant]) {
        self.totalCount = totalCount; self.activeCount = activeCount; self.completedCount = completedCount
        self.completionRate = completionRate; self.activeStreak = activeStreak
        self.longestStreak = longestStreak; self.lastSevenDays = lastSevenDays
        self.quadrantStats = quadrantStats; self.topTags = topTags
        self.overdueCount = overdueCount; self.dueTodayCount = dueTodayCount
        self.dueThisWeekCount = dueThisWeekCount; self.upcomingDeadlines = upcomingDeadlines
        self.trend = trend; self.totalTrackedMinutes = totalTrackedMinutes; self.timeByQuadrant = timeByQuadrant
    }

    /// The all-zero summary for an empty task set (drives the Dashboard empty state).
    public static func empty(trendDays: Int, now: Date, calendar: Calendar) -> AnalyticsSummary {
        AnalyticsEngine.compute(tasks: [], now: now, calendar: calendar, trendDays: trendDays)
    }
}
```

- [ ] **Step 2: Commit:** `git add GSDKit/Sources/GSDModel/AnalyticsSummary.swift && git commit -m "feat: add AnalyticsSummary metric bundle for the dashboard"`

> No test on its own — it is exercised entirely through `AnalyticsEngine` in A2. `.empty` forwards to the engine so there is one code path.

### Task A2: `AnalyticsEngine.compute` (every §6.15 metric)

**Files:**
- Create: `GSDKit/Sources/GSDModel/AnalyticsEngine.swift`
- Test: `GSDKit/Tests/GSDModelTests/AnalyticsEngineTests.swift`

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/AnalyticsEngineTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct AnalyticsEngineTests {
    /// Fixed UTC gregorian calendar; now = Mon 2026-06-15 09:00 UTC (matches the probe).
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var dc = DateComponents(); dc.year = y; dc.month = m; dc.day = d; dc.hour = h
        return cal.date(from: dc)!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func task(_ id: String, urgent: Bool = false, important: Bool = false,
                      completed: Bool = false, completedAt: Date? = nil, due: Date? = nil,
                      tags: [String] = [], created: Date? = nil,
                      entries: [TimeEntry] = [], timeSpent: Int? = nil) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             completedAt: completedAt, createdAt: created ?? day(2026, 6, 1),
             updatedAt: day(2026, 6, 1), dueDate: due, tags: tags,
             timeSpent: timeSpent, timeEntries: entries)
    }
    private func compute(_ tasks: [Task], trendDays: Int = 7) -> AnalyticsSummary {
        AnalyticsEngine.compute(tasks: tasks, now: now, calendar: cal, trendDays: trendDays)
    }

    @Test func emptySetIsAllZeroWithoutCrashing() {
        let s = compute([])
        #expect(s.totalCount == 0 && s.activeCount == 0 && s.completedCount == 0)
        #expect(s.completionRate == 0)                 // div-by-zero guard
        #expect(s.activeStreak == 0 && s.longestStreak == 0)
        #expect(s.lastSevenDays == [false, false, false, false, false, false, false])
        #expect(s.quadrantStats.count == 4)            // always 4, even empty
        #expect(s.trend.count == 7)
        #expect(s.upcomingDeadlines.isEmpty && s.topTags.isEmpty)
        #expect(s.totalTrackedMinutes == 0)
    }
    @Test func countsAndCompletionRate() {
        let ts = [task("a"), task("b"), task("c", completed: true, completedAt: day(2026, 6, 15))]
        let s = compute(ts)
        #expect(s.totalCount == 3 && s.activeCount == 2 && s.completedCount == 1)
        #expect(abs(s.completionRate - (1.0 / 3.0)) < 1e-9)
    }
    @Test func quadrantStatsAreFourInOrderWithPerQuadrantCompletion() {
        let ts = [task("q1a", urgent: true, important: true),
                  task("q1b", urgent: true, important: true, completed: true, completedAt: day(2026, 6, 15)),
                  task("q4", urgent: false, important: false)]
        let s = compute(ts)
        #expect(s.quadrantStats.map(\.quadrant) == Quadrant.allCases)   // Q1→Q4
        let q1 = s.quadrantStats[0]
        #expect(q1.total == 2 && q1.completed == 1)
        #expect(abs(q1.completionRate - 0.5) < 1e-9)
        #expect(s.quadrantStats[1].total == 0 && s.quadrantStats[1].completionRate == 0)
    }
    @Test func activeStreakLenientTodayZero() {
        // today (6/15) has 0; yesterday 6/14 + 6/13 have completions → lenient active = 2.
        let ts = [task("a", completed: true, completedAt: day(2026, 6, 14)),
                  task("b", completed: true, completedAt: day(2026, 6, 13))]
        #expect(compute(ts).activeStreak == 2)
    }
    @Test func activeStreakCountsTodayWhenPresentAndGapBreaks() {
        let ts = [task("t", completed: true, completedAt: day(2026, 6, 15)),
                  task("y", completed: true, completedAt: day(2026, 6, 14)),
                  task("g", completed: true, completedAt: day(2026, 6, 12))]   // gap at 6/13
        #expect(compute(ts).activeStreak == 2)
    }
    @Test func longestStreakOverHistory() {
        let ts = [task("a", completed: true, completedAt: day(2026, 6, 1)),
                  task("b", completed: true, completedAt: day(2026, 6, 2)),
                  task("c", completed: true, completedAt: day(2026, 6, 3)),
                  task("d", completed: true, completedAt: day(2026, 6, 10))]
        #expect(compute(ts).longestStreak == 3)
    }
    @Test func lastSevenDaysArray() {
        let ts = [task("t", completed: true, completedAt: day(2026, 6, 15)),
                  task("m", completed: true, completedAt: day(2026, 6, 13)),
                  task("o", completed: true, completedAt: day(2026, 6, 9))]
        #expect(compute(ts).lastSevenDays == [true, false, false, false, true, false, true])
    }
    @Test func deadlineCounts() {
        let ts = [task("od", due: day(2026, 6, 14)),                       // overdue
                  task("today", due: day(2026, 6, 15)),                    // due today
                  task("w6", due: day(2026, 6, 21)),                       // this week (within +7)
                  task("doneOd", completed: true, completedAt: day(2026, 6, 14), due: day(2026, 6, 10))]
        let s = compute(ts)
        #expect(s.overdueCount == 1)      // completed-overdue excluded
        #expect(s.dueTodayCount == 1)
        #expect(s.dueThisWeekCount == 2)  // today + w6 (half-open [today, +7))
    }
    @Test func upcomingDeadlinesSortedActiveFutureDated() {
        let ts = [task("late", due: day(2026, 6, 25)),
                  task("soon", due: day(2026, 6, 16)),
                  task("od", due: day(2026, 6, 14)),                        // overdue excluded
                  task("none")]                                            // undated excluded
        #expect(compute(ts).upcomingDeadlines.map(\.id) == ["soon", "late"])
    }
    @Test func topTagsDescByCount() {
        let ts = [task("a", tags: ["home", "errand"]), task("b", tags: ["home"]),
                  task("c", tags: ["home", "errand"]), task("d", tags: ["work"])]
        let s = compute(ts)
        #expect(s.topTags.first?.tag == "home" && s.topTags.first?.count == 3)
        #expect(Set(s.topTags.map(\.tag)) == ["home", "errand", "work"])
    }
    @Test func trendBuckets() {
        let ts = [task("a", created: day(2026, 6, 15)),
                  task("b", created: day(2026, 6, 9), completed: true, completedAt: day(2026, 6, 14))]
        let s = compute(ts, trendDays: 7)
        #expect(s.trend.count == 7)
        #expect(s.trend.first?.date == cal.startOfDay(for: day(2026, 6, 9)))
        #expect(s.trend.last?.created == 1)                                // today (6/15)
        #expect(s.trend.first?.created == 1)                               // 6/9
        let b14 = s.trend.first { $0.date == cal.startOfDay(for: day(2026, 6, 14)) }!
        #expect(b14.completed == 1)
    }
    @Test func trendHonorsRequestedLength() {
        #expect(compute([], trendDays: 30).trend.count == 30)
        #expect(compute([], trendDays: 90).trend.count == 90)
    }
    @Test func timeTrackingSummary() {
        // 90 minutes in Q1 (via timeSpent), 30 minutes in Q4 (via a closed entry).
        let q1 = task("q1", urgent: true, important: true, timeSpent: 90)
        let q4 = task("q4", entries: [TimeEntry(id: "e", startedAt: day(2026, 6, 1, 10),
                                                endedAt: day(2026, 6, 1, 10).addingTimeInterval(30 * 60))])
        let s = compute([q1, q4])
        #expect(s.totalTrackedMinutes == 120)
        #expect(s.timeByQuadrant.count == 4)
        #expect(s.timeByQuadrant[0].minutes == 90)   // Q1
        #expect(s.timeByQuadrant[3].minutes == 30)   // Q4
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter AnalyticsEngineTests` → FAIL (`AnalyticsEngine` not found).

- [ ] **Step 3: Write `AnalyticsEngine.swift`** (pure; date math probe-verified — streak.swift 10/10, trend.swift 13/13):
```swift
import Foundation

/// Computes every dashboard metric (product spec §6.15) from a task set, with injected
/// `now`/`calendar` so all date math is deterministic. Pure: value-in/value-out, no
/// side effects, no `Date()`/`Calendar.current`. Streak + trend logic is PROBE-VERIFIED.
public enum AnalyticsEngine {
    /// Cap on `topTags` / `upcomingDeadlines` so the dashboard renders a bounded list.
    public static let topTagsLimit = 8
    public static let upcomingLimit = 5

    public static func compute(tasks: [Task], now: Date, calendar: Calendar, trendDays: Int) -> AnalyticsSummary {
        let startToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: startToday)!   // [startToday, +7)

        // Counts
        let total = tasks.count
        let completed = tasks.filter(\.completed)
        let completedCount = completed.count
        let activeCount = total - completedCount
        let completionRate = total == 0 ? 0 : Double(completedCount) / Double(total)

        // Streaks (probe-pinned). A completion day = startOfDay(completedAt).
        let completionDays = Set(completed.compactMap { $0.completedAt }.map { calendar.startOfDay(for: $0) })
        let activeStreak = Self.activeStreak(startToday: startToday, days: completionDays, calendar: calendar)
        let longestStreak = Self.longestStreak(days: completionDays, calendar: calendar)
        let lastSevenDays = (0..<7).map { offset -> Bool in
            let d = calendar.date(byAdding: .day, value: -(6 - offset), to: startToday)!
            return completionDays.contains(d)
        }

        // Quadrant distribution (always 4, Q1→Q4).
        let quadrantStats = Quadrant.allCases.map { q -> AnalyticsSummary.QuadrantStat in
            let inQ = tasks.filter { $0.quadrant == q }
            return .init(quadrant: q, total: inQ.count, completed: inQ.filter(\.completed).count)
        }

        // Tag stats (desc by count, then tag for stability; capped).
        var tagCounts: [String: Int] = [:]
        for t in tasks { for tag in t.tags { tagCounts[tag, default: 0] += 1 } }
        let topTags = tagCounts.map { AnalyticsSummary.TagStat(tag: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.tag < $1.tag : $0.count > $1.count }
            .prefix(topTagsLimit).map { $0 }

        // Deadlines (active only).
        let active = tasks.filter { !$0.completed }
        let overdueCount = active.filter { ($0.dueDate.map { $0 < startToday }) ?? false }.count
        let dueTodayCount = active.filter { ($0.dueDate.map { calendar.isDate($0, inSameDayAs: now) }) ?? false }.count
        let dueThisWeekCount = active.filter { ($0.dueDate.map { $0 >= startToday && $0 < weekEnd }) ?? false }.count
        let upcomingDeadlines = active
            .filter { ($0.dueDate.map { $0 >= startToday }) ?? false }
            .sorted { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            .prefix(upcomingLimit).map { $0 }

        // Completion trend (probe-pinned half-open buckets; index 0 = oldest, N-1 = today).
        let n = max(0, trendDays)
        let trend = (0..<n).map { i -> AnalyticsSummary.TrendPoint in
            let bucketStart = calendar.date(byAdding: .day, value: -(n - 1 - i), to: startToday)!
            let bucketEnd = calendar.date(byAdding: .day, value: 1, to: bucketStart)!
            let created = tasks.filter { $0.createdAt >= bucketStart && $0.createdAt < bucketEnd }.count
            let comp = tasks.filter { t in
                guard let at = t.completedAt else { return false }
                return at >= bucketStart && at < bucketEnd
            }.count
            return .init(date: bucketStart, created: created, completed: comp)
        }

        // Time tracking. Prefer the persisted `timeSpent`; fall back to recomputing from entries.
        func minutes(_ t: Task) -> Int { t.timeSpent ?? TimeTracking.timeSpentMinutes(t.timeEntries) }
        let totalTracked = tasks.reduce(0) { $0 + minutes($1) }
        let timeByQuadrant = Quadrant.allCases.map { q -> AnalyticsSummary.TimeByQuadrant in
            .init(quadrant: q, minutes: tasks.filter { $0.quadrant == q }.reduce(0) { $0 + minutes($1) })
        }

        return AnalyticsSummary(
            totalCount: total, activeCount: activeCount, completedCount: completedCount,
            completionRate: completionRate, activeStreak: activeStreak, longestStreak: longestStreak,
            lastSevenDays: lastSevenDays, quadrantStats: quadrantStats, topTags: topTags,
            overdueCount: overdueCount, dueTodayCount: dueTodayCount, dueThisWeekCount: dueThisWeekCount,
            upcomingDeadlines: upcomingDeadlines, trend: trend,
            totalTrackedMinutes: totalTracked, timeByQuadrant: timeByQuadrant)
    }

    /// Consecutive completion days ending at today, or — when today is empty — starting
    /// at yesterday (LENIENT today-with-zero rule, probe-pinned). 0 when neither today
    /// nor yesterday has a completion.
    private static func activeStreak(startToday: Date, days: Set<Date>, calendar: Calendar) -> Int {
        var cursor = days.contains(startToday)
            ? startToday
            : calendar.date(byAdding: .day, value: -1, to: startToday)!
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return streak
    }

    /// Longest run of consecutive completion days over all history; 0 when none.
    private static func longestStreak(days: Set<Date>, calendar: Calendar) -> Int {
        guard !days.isEmpty else { return 0 }
        let sorted = days.sorted()
        var longest = 1, run = 1
        for i in 1..<sorted.count {
            if let next = calendar.date(byAdding: .day, value: 1, to: sorted[i - 1]), next == sorted[i] {
                run += 1; longest = max(longest, run)
            } else {
                run = 1
            }
        }
        return longest
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter AnalyticsEngineTests` → PASS (13 tests). Re-run full `cd GSDKit && swift test` → still green (no 3a/3b regression).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/AnalyticsEngine.swift GSDKit/Tests/GSDModelTests/AnalyticsEngineTests.swift && git commit -m "feat: add pure AnalyticsEngine computing every dashboard metric"`

> **Probe note:** streak math (active incl. lenient today-with-zero, longest, last-7) verified in `/tmp/p3c-probe/streak.swift` (10/10); trend half-open buckets at N ∈ {7,30,90} in `/tmp/p3c-probe/trend.swift` (13/13), before this plan shipped.

### Task A3: `TaskStore.analytics(trendDays:)` thin wrapper

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreAnalyticsTests.swift` (new — mirrors 3a's `TaskStoreFilterTests` rigor: a one-test suite confirming the store delegates over its live snapshot with its injected clock/calendar).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreAnalyticsTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreAnalyticsTests {
    /// now = 2026-06-15 09:00 UTC (matches the engine fixtures).
    private let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.hour = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let fixed = now
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { fixed }, calendar: utcCalendar())
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.tasks.count != count && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }

    @Test func analyticsComputesOverLiveSnapshotWithStoreClock() async throws {
        let store = try makeStore()
        store.start()
        try await store.create(Task(id: "a", title: "A", urgent: true, important: true,
                                    createdAt: now, updatedAt: now))
        try await store.create(Task(id: "b", title: "B", urgent: false, important: false,
                                    completed: true, completedAt: now, createdAt: now, updatedAt: now))
        try await waitForTasks(store, count: 2)
        let summary = store.analytics(trendDays: 7)
        #expect(summary.totalCount == 2 && summary.completedCount == 1)
        #expect(summary.trend.count == 7)
        #expect(summary.trend.last?.created == 2)   // both created "today" via the store clock
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreAnalyticsTests` → FAIL (`analytics(trendDays:)` not found).

- [ ] **Step 3: Add to `TaskStore`** in the `// MARK: Reads` section, after `tasks(matching:)`:
```swift
    /// The dashboard summary over the live task snapshot, resolved with the store's
    /// injected clock/calendar. Pure/derived — delegates to `AnalyticsEngine`; never mutates.
    public func analytics(trendDays: Int) -> AnalyticsSummary {
        AnalyticsEngine.compute(tasks: tasks, now: clock(), calendar: calendar, trendDays: trendDays)
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreAnalyticsTests` → PASS (1 test). Re-run full `cd GSDKit && swift test` → still green (additive; nothing breaks).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreAnalyticsTests.swift && git commit -m "feat: add TaskStore.analytics(trendDays:) dashboard query"`

> **Milestone after Group A:** the analytics engine + store query are green via `swift test`. Run `cd GSDKit && swift test --filter AnalyticsEngineTests` and the full `swift test` (no regression) before the Dashboard UI.

---

## Group C — Import/Export pure logic + store methods (`GSDModel`/`GSDStore`, `swift test`)

> Pure logic first, then the store methods. Run from the package root: `cd GSDKit && swift test --filter <SuiteName>`. Maps **A30** (export) + **A31** (import) + part of **A32** (erase, store side). Lands BEFORE the UI that consumes it (Group D).

### Task C0: Make `Task` leniently decodable (custom `init(from:)`)

**Files:**
- Modify: `GSDKit/Sources/GSDModel/Task.swift`
- Test: `GSDKit/Tests/GSDModelTests/TaskLenientDecodeTests.swift`

Per convention 9: `Task`'s *synthesized* `Codable` throws on any absent non-optional key, so a legacy/web export omitting `tags`/`completed`/etc. would fail to decode. Add a custom `init(from:)` that requires only the 6 no-default fields and defaults the rest; keep `encode(to:)` synthesized. **PROBE-VERIFIED** (`/tmp/p3c-probe/task_lenient.swift`, 9/9). Lands first in Group C because both `TaskExport` round-trips (C1) and `TaskImporter` lenient decode (C2) depend on it.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/TaskLenientDecodeTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct TaskLenientDecodeTests {
    /// Fractional-seconds ISO-8601 decoder (matches the export codec).
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }

    @Test func decodesLegacyTaskWithOnlyRequiredKeysFillingDefaults() throws {
        // Only the 6 required keys + a legacy unknown key; every defaulted field omitted.
        let json = """
        {"id":"ok","title":"Legacy","urgent":true,"important":false,
         "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z",
         "vectorClock":{"node":5}}
        """
        let t = try decoder().decode(Task.self, from: Data(json.utf8))
        #expect(t.id == "ok" && t.urgent == true && t.important == false)
        #expect(t.tags == [] && t.subtasks == [] && t.dependencies == [])     // defaulted
        #expect(t.completed == false && t.description == "")
        #expect(t.recurrence == .none)
        #expect(t.notificationEnabled == true)                                // non-false default preserved
        #expect(t.dueDate == nil && t.completedAt == nil && t.parentTaskId == nil)  // optionals → nil
    }
    @Test func throwsWhenRequiredFieldMissing() {
        let json = """
        {"id":"x","title":"No createdAt","urgent":false,"important":false,
         "updatedAt":"1970-01-01T00:00:00.000Z"}
        """
        #expect(throws: (any Error).self) { _ = try decoder().decode(Task.self, from: Data(json.utf8)) }
    }
    @Test func throwsOnWrongTypedRequiredField() {
        let json = """
        {"id":"bad","title":42,"urgent":true,"important":true,
         "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z"}
        """
        #expect(throws: (any Error).self) { _ = try decoder().decode(Task.self, from: Data(json.utf8)) }
    }
    @Test func encodeThenDecodeRoundTripsEqual() throws {
        let original = Task(id: "r", title: "Round", urgent: true, important: true,
                            createdAt: Date(timeIntervalSince1970: 0.5),
                            updatedAt: Date(timeIntervalSince1970: 0.5),
                            tags: ["a"], dueDate: Date(timeIntervalSince1970: 100))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: date))
        }
        let back = try decoder().decode(Task.self, from: try encoder.encode(original))
        #expect(back == original)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskLenientDecodeTests` → the legacy-defaults test FAILS (synthesized `Codable` throws on the missing `tags` key); the others may pass incidentally.

- [ ] **Step 3: Edit `Task.swift`.** Add an explicit `CodingKeys` (stored properties only — `quadrant` is computed and MUST be excluded) and a custom `init(from:)`. Append these inside the `Task` struct, after the member `init(...)`:
```swift
    /// Stored properties only. `quadrant` is computed (never persisted/encoded) and is
    /// deliberately absent so synthesized `encode(to:)` skips it.
    private enum CodingKeys: String, CodingKey {
        case id, title, description, urgent, important, completed, completedAt
        case createdAt, updatedAt, dueDate, recurrence, tags, subtasks, dependencies
        case parentTaskId, notifyBefore, notificationEnabled, notificationSent
        case lastNotificationAt, snoozedUntil, estimatedMinutes, timeSpent, timeEntries
    }

    /// Lenient decode (import tolerance — design-spec §3): require only the fields that
    /// have no member-init default; default every other field exactly as the member init
    /// does. Unknown keys are ignored. `encode(to:)` stays synthesized. A task missing a
    /// required field or carrying a wrong-typed value throws (the importer skips+counts it).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        urgent = try c.decode(Bool.self, forKey: .urgent)
        important = try c.decode(Bool.self, forKey: .important)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        recurrence = try c.decodeIfPresent(RecurrenceType.self, forKey: .recurrence) ?? .none
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        subtasks = try c.decodeIfPresent([Subtask].self, forKey: .subtasks) ?? []
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        parentTaskId = try c.decodeIfPresent(String.self, forKey: .parentTaskId)
        notifyBefore = try c.decodeIfPresent(Int.self, forKey: .notifyBefore)
        notificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationEnabled) ?? true
        notificationSent = try c.decodeIfPresent(Bool.self, forKey: .notificationSent) ?? false
        lastNotificationAt = try c.decodeIfPresent(Date.self, forKey: .lastNotificationAt)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        timeSpent = try c.decodeIfPresent(Int.self, forKey: .timeSpent)
        timeEntries = try c.decodeIfPresent([TimeEntry].self, forKey: .timeEntries) ?? []
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskLenientDecodeTests` → PASS (4 tests). Re-run full `cd GSDKit && swift test` → **must stay green**: `TaskRecord.toDomain()` builds `Task` from columns via the member init (not JSON decode), and the embedded `[Subtask]`/`[TimeEntry]`/`[String]` columns decode via their own untouched `Codable`, so GRDB is unaffected. If any existing test decoded a partial `Task` strictly and relied on a throw, it would surface here (grep confirmed none exist).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/Task.swift GSDKit/Tests/GSDModelTests/TaskLenientDecodeTests.swift && git commit -m "feat: add lenient Task.init(from:) defaulting missing keys for import tolerance"`

> **Probe note:** the custom-`init(from:)` + synthesized-`encode` + explicit-`CodingKeys` shape (computed `quadrant` excluded, required-vs-defaulted split, round-trip) was verified in `/tmp/p3c-probe/task_lenient.swift` (9/9) before this plan shipped.

### Task C1: `TaskExport` (Codable envelope + self-owned codec)

**Files:**
- Create: `GSDKit/Sources/GSDModel/TaskExport.swift`
- Test: `GSDKit/Tests/GSDModelTests/TaskExportTests.swift`

The export envelope plus a GSDModel-local fractional-seconds ISO-8601 codec (GSDModel cannot import GSDStore's internal `GSDJSON` — see convention 5). `encode`/`decode` are the single entry points the store calls.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/TaskExportTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct TaskExportTests {
    private func task(_ id: String, due: Date? = nil) -> Task {
        Task(id: id, title: id, urgent: true, important: true,
             createdAt: Date(timeIntervalSince1970: 1_700_000_000),
             updatedAt: Date(timeIntervalSince1970: 1_700_000_000), dueDate: due)
    }

    @Test func envelopeShapeHasTasksExportedAtVersion() throws {
        let export = TaskExport(tasks: [task("a")], exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let json = String(decoding: try TaskExport.encode(export), as: UTF8.self)
        #expect(json.contains("\"tasks\""))
        #expect(json.contains("\"exportedAt\""))
        #expect(json.contains("\"version\":1"))
    }
    @Test func versionDefaultsToOne() {
        #expect(TaskExport(tasks: [], exportedAt: Date()).version == 1)
    }
    @Test func roundTripsPreservingTasks() throws {
        let original = TaskExport(tasks: [task("a", due: Date(timeIntervalSince1970: 1_700_600_000)), task("b")],
                                  exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let decoded = try TaskExport.decode(try TaskExport.encode(original))
        #expect(decoded.tasks.map(\.id) == ["a", "b"])
        #expect(decoded.tasks.first?.dueDate == original.tasks.first?.dueDate)
        #expect(decoded.version == 1)
    }
    @Test func datesUseFractionalSecondsISO8601() throws {
        // 500ms past the epoch-aligned second → fractional-seconds component must survive.
        let t = Task(id: "x", title: "x", urgent: false, important: false,
                     createdAt: Date(timeIntervalSince1970: 0.5),
                     updatedAt: Date(timeIntervalSince1970: 0.5))
        let json = String(decoding: try TaskExport.encode(TaskExport(tasks: [t], exportedAt: Date(timeIntervalSince1970: 0.5))), as: UTF8.self)
        #expect(json.contains(".500Z"))
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskExportTests` → FAIL (`TaskExport` not found).

- [ ] **Step 3: Write `TaskExport.swift`:**
```swift
import Foundation

/// The export/import envelope (design-spec §3): a versioned set of tasks plus a timestamp.
/// `version` lets future imports branch on schema changes (currently always 1).
public struct TaskExport: Codable, Equatable, Sendable {
    public var tasks: [Task]
    public var exportedAt: Date
    public var version: Int

    public init(tasks: [Task], exportedAt: Date, version: Int = 1) {
        self.tasks = tasks
        self.exportedAt = exportedAt
        self.version = version
    }

    /// GSDModel-local fractional-seconds ISO-8601 coders. GSDModel cannot import GSDStore's
    /// internal `GSDJSON`, so this mirrors its strategy verbatim (design-spec round-trip
    /// fidelity decision). Each call builds its own `ISO8601DateFormatter` instance because
    /// the type is not `Sendable` (matches the GSDJSON pattern).
    private static func makeFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    public static func encode(_ export: TaskExport) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(makeFormatter().string(from: date))
        }
        return try encoder.encode(export)
    }

    public static func decode(_ data: Data) throws -> TaskExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = makeFormatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ISO-8601 date: \(s)")
            }
            return date
        }
        return try decoder.decode(TaskExport.self, from: data)
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskExportTests` → PASS (4 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/TaskExport.swift GSDKit/Tests/GSDModelTests/TaskExportTests.swift && git commit -m "feat: add TaskExport envelope with fractional-seconds ISO-8601 codec"`

### Task C2: `TaskImporter` (lenient decode + merge id-remap + replace + limits)

**Files:**
- Create: `GSDKit/Sources/GSDModel/TaskImporter.swift`
- Test: `GSDKit/Tests/GSDModelTests/TaskImporterTests.swift`

Pure: takes raw `Data` + the existing id set + a `newID` closure, returns an `ImportResult` (the tasks to write + counts). The store does the actual writing. Merge id-remap is two-phase (PROBE-VERIFIED — merge.swift 12/12).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/TaskImporterTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct TaskImporterTests {
    private func task(_ id: String, deps: [String] = [], parent: String? = nil) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             dependencies: deps, parentTaskId: parent)
    }
    private func data(_ tasks: [Task]) throws -> Data {
        try TaskExport.encode(TaskExport(tasks: tasks, exportedAt: Date(timeIntervalSince1970: 0)))
    }
    private func counter(_ prefix: String) -> () -> String {
        var n = 0; return { n += 1; return "\(prefix)\(n)" }
    }

    // MARK: replace
    @Test func replaceReturnsAllTasksUnchanged() throws {
        let result = try TaskImporter.replace(from: try data([task("a"), task("b")]))
        #expect(result.tasks.map(\.id) == ["a", "b"])
        #expect(result.skipped == 0)
    }

    // MARK: merge id-remap (two-phase)
    @Test func mergeRegeneratesCollidingIdAndRemapsForwardDependency() throws {
        // B listed before A; B depends on A; A collides with an existing id.
        let bytes = try data([task("B", deps: ["A"]), task("A")])
        let result = try TaskImporter.merge(from: bytes, existingIDs: ["A"], newID: counter("new-"))
        let a = result.tasks.first { $0.dependencies.isEmpty }!
        let b = result.tasks.first { $0.id == "B" }!
        #expect(a.id == "new-1")                  // A regenerated
        #expect(b.dependencies == ["new-1"])      // B's forward dep remapped
    }
    @Test func mergeRemapsParentTaskId() throws {
        let bytes = try data([task("child", parent: "parent"), task("parent")])
        let result = try TaskImporter.merge(from: bytes, existingIDs: ["parent"], newID: counter("g-"))
        let child = result.tasks.first { $0.id == "child" }!
        #expect(result.tasks.contains { $0.id == "g-1" })
        #expect(child.parentTaskId == "g-1")
    }
    @Test func mergeLeavesNonCollidingAndDanglingRefsUntouched() throws {
        let bytes = try data([task("x", deps: ["ghost"], parent: "z")])
        let result = try TaskImporter.merge(from: bytes, existingIDs: ["other"], newID: counter("n-"))
        #expect(result.tasks[0].id == "x")
        #expect(result.tasks[0].dependencies == ["ghost"])   // dangling ref preserved
        #expect(result.tasks[0].parentTaskId == "z")
    }

    // MARK: lenient decode
    @Test func lenientDecodeIgnoresUnknownKeysAndFillsMissing() throws {
        // A hand-rolled envelope: one task with ONLY the 6 required keys (every defaulted
        // field omitted) + a legacy `vectorClock` key — decodes via C0's lenient init; one
        // task structurally broken (title is a number) — skipped + counted.
        let json = """
        {"version":1,"exportedAt":"1970-01-01T00:00:00.000Z","tasks":[
          {"id":"ok","title":"Legacy","urgent":true,"important":false,
           "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z",
           "vectorClock":{"node":5}},
          {"id":"bad","title":42,"urgent":true,"important":true,
           "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z"}
        ]}
        """
        let result = try TaskImporter.replace(from: Data(json.utf8))
        #expect(result.tasks.map(\.id) == ["ok"])   // bad task skipped
        #expect(result.skipped == 1)
        #expect(result.tasks.first?.urgent == true)  // decoded fields preserved
        #expect(result.tasks.first?.tags == [])      // missing key → default
    }

    // MARK: limits
    @Test func tooManyTasksThrows() throws {
        let many = (0..<(TaskImporter.maxImportTasks + 1)).map { task("t\($0)") }
        #expect(throws: ImportError.self) { _ = try TaskImporter.replace(from: try data(many)) }
    }
    @Test func oversizedPayloadThrows() throws {
        let big = Data(count: TaskImporter.maxImportBytes + 1)
        #expect(throws: ImportError.self) { _ = try TaskImporter.replace(from: big) }
    }
    @Test func malformedEnvelopeThrows() throws {
        #expect(throws: ImportError.self) { _ = try TaskImporter.replace(from: Data("not json".utf8)) }
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskImporterTests` → FAIL (`TaskImporter`/`ImportError` not found).

- [ ] **Step 3: Write `TaskImporter.swift`** (merge two-phase, PROBE-VERIFIED):
```swift
import Foundation

public enum ImportError: Error, Equatable {
    case payloadTooLarge(bytes: Int)
    case tooManyTasks(count: Int)
    case malformed(String)
}

/// The outcome of a pure import parse: the tasks the store should write, plus how many
/// raw task entries were skipped (failed lenient decode).
public struct ImportResult: Equatable, Sendable {
    public let tasks: [Task]
    public let skipped: Int
    public init(tasks: [Task], skipped: Int) { self.tasks = tasks; self.skipped = skipped }
}

/// Pure import parsing (design-spec §3): lenient per-task decode (unknown keys ignored,
/// missing optionals defaulted, a structurally-broken task skipped+counted), enforced
/// limits, and the two import modes. `merge` regenerates colliding ids and remaps internal
/// references; `replace` returns the parsed set verbatim. The store does the writing.
public enum TaskImporter {
    public static let maxImportTasks = 10_000
    public static let maxImportBytes = 10 * 1024 * 1024   // ~10 MB

    /// Replace-mode parse: validate limits + lenient-decode; return the set as-is.
    public static func replace(from data: Data) throws -> ImportResult {
        try parse(data)
    }

    /// Merge-mode parse: as `replace`, then two-phase id-remap of any task whose id
    /// collides with an existing store id, remapping `dependencies`/`parentTaskId`
    /// references through the complete map (forward references handled).
    public static func merge(from data: Data, existingIDs: Set<String>,
                             newID: () -> String) throws -> ImportResult {
        let parsed = try parse(data)

        // Phase 1: assign new ids to colliding imported tasks; a new id must collide with
        // neither existing ids, other imported ids, nor already-assigned new ids.
        var reserved = existingIDs.union(parsed.tasks.map(\.id))
        var remap: [String: String] = [:]
        for task in parsed.tasks where existingIDs.contains(task.id) {
            var candidate = newID()
            while reserved.contains(candidate) { candidate = newID() }
            remap[task.id] = candidate
            reserved.insert(candidate)
        }

        // Phase 2: rewrite ids + internal references through the complete map.
        let remapped = parsed.tasks.map { task -> Task in
            var t = task
            t.id = remap[task.id] ?? task.id
            t.dependencies = task.dependencies.map { remap[$0] ?? $0 }
            if let p = task.parentTaskId { t.parentTaskId = remap[p] ?? p }
            return t
        }
        return ImportResult(tasks: remapped, skipped: parsed.skipped)
    }

    // MARK: parsing

    /// Decode the envelope leniently: read `tasks` as raw JSON values, decode each task
    /// independently (skip+count failures), enforce the byte + count limits.
    private static func parse(_ data: Data) throws -> ImportResult {
        guard data.count <= maxImportBytes else { throw ImportError.payloadTooLarge(bytes: data.count) }

        // Decode the envelope structurally, leaving `tasks` as opaque per-task containers
        // so one bad task doesn't fail the whole decode.
        let envelope: LenientEnvelope
        do {
            envelope = try TaskExport.decoder().decode(LenientEnvelope.self, from: data)
        } catch {
            throw ImportError.malformed("\(error)")
        }

        guard envelope.tasks.count <= maxImportTasks else {
            throw ImportError.tooManyTasks(count: envelope.tasks.count)
        }

        var tasks: [Task] = []
        var skipped = 0
        for raw in envelope.tasks {
            if let task = raw.decoded { tasks.append(task) } else { skipped += 1 }
        }
        return ImportResult(tasks: tasks, skipped: skipped)
    }

    /// Envelope whose `tasks` are decoded one-at-a-time via `LenientTask` so a single
    /// malformed entry is isolated. Unknown envelope keys are ignored by `Codable` default.
    private struct LenientEnvelope: Decodable {
        let tasks: [LenientTask]
    }
    /// Wraps a per-task decode attempt. `Task` already defaults its optional fields and
    /// `Codable` ignores unknown keys, so a missing-key or extra-key task decodes fine;
    /// only a structurally-broken task (wrong value type) yields `nil`.
    private struct LenientTask: Decodable {
        let decoded: Task?
        init(from decoder: Decoder) throws {
            decoded = try? Task(from: decoder)
        }
    }
}

extension TaskExport {
    /// Reuse the export decoder (fractional-seconds ISO-8601) for imports.
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad ISO-8601 date: \(s)")
            }
            return date
        }
        return decoder
    }
}
```

> **Note on `LenientTask`:** `try? Task(from: decoder)` swallows decode errors per-task → that task is skipped + counted. The leniency itself lives in the **custom `Task.init(from:)` added in Task C0** (NOT here, and NOT in synthesized `Codable` — which would throw on a missing non-optional `tags`/`subtasks`/etc. key, the bug C0 fixes): C0's init defaults every non-required field, so a task carrying a legacy `vectorClock` or omitting `tags`/`subtasks`/`completed` decodes successfully; only a wrong-typed value or a missing *required* field (`id`/`title`/`urgent`/`important`/`createdAt`/`updatedAt`) fails. The `TaskExport.decoder()` extension is added here (not C1) because import is its first consumer; C1's `TaskExport.decode` keeps its own inline decoder for the whole-envelope path — both share the identical date strategy (documented duplication, < 10 lines, per the project's "a little duplication over a forced abstraction" call).

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskImporterTests` → PASS (8 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/TaskImporter.swift GSDKit/Tests/GSDModelTests/TaskImporterTests.swift && git commit -m "feat: add TaskImporter (lenient decode, two-phase merge id-remap, limits)"`

> **Probe note:** the two-phase merge id-remap (forward-reference dependency remap, `parentTaskId` remap, non-colliding/dangling refs preserved, regenerated id avoiding imported-id collisions) was verified in `/tmp/p3c-probe/merge.swift` (12/12) before this plan shipped.

### Task C3: `TaskRepository.replaceAll(_:)` single-transaction clear+insert

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskRepositoryReplaceTests.swift`

Replace-mode import must clear all active tasks then insert the imported set in ONE transaction — NOT a loop of per-id `delete` (whose O(n) dependency-scrub scan makes a 10k clear O(n²)). A bare `deleteAll` + bulk `save` is correct here: the scrub only matters when removing a SUBSET (dangling references in survivors); a full clear has no survivors.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskRepositoryReplaceTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct TaskRepositoryReplaceTests {
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func replaceAllClearsThenInserts() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(task("old1"))
        try await repo.upsert(task("old2"))
        try await repo.replaceAll([task("new1"), task("new2"), task("new3")])
        let all = try await repo.fetchAll()
        #expect(Set(all.map(\.id)) == ["new1", "new2", "new3"])
    }
    @Test func replaceAllWithEmptyClearsEverything() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(task("a"))
        try await repo.replaceAll([])
        #expect(try await repo.fetchAll().isEmpty)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskRepositoryReplaceTests` → FAIL (`replaceAll` not found).

- [ ] **Step 3: Edit `TaskRepository.swift`.** Add to the protocol (after `delete(id:)`):
```swift
    /// Replace the entire task table in a single transaction: delete all rows, then insert
    /// `tasks`. Used by Replace-mode import. No dependency-scrub is needed (a full clear
    /// leaves no surviving rows that could reference a deleted id).
    func replaceAll(_ tasks: [Task]) async throws
```
and to `GRDBTaskRepository` (after `delete(id:)`):
```swift
    public func replaceAll(_ tasks: [Task]) async throws {
        let records = try tasks.map { try TaskRecord($0) }
        try await dbWriter.write { db in
            _ = try TaskRecord.deleteAll(db)
            for record in records { try record.insert(db) }
        }
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskRepositoryReplaceTests` → PASS (2 tests). Re-run full `cd GSDKit && swift test` → green.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskRepository.swift GSDKit/Tests/GSDStoreTests/TaskRepositoryReplaceTests.swift && git commit -m "feat: add TaskRepository.replaceAll for single-transaction Replace import"`

### Task C4: `TaskStore` exportJSON / importTasks / eraseAllData

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreDataTests.swift`

The store wires the pure logic to persistence. `exportJSON()` reads the live snapshot; `importTasks(_:mode:)` parses then writes (Replace via `replaceAll`, Merge via per-task `save` which stamps `updatedAt`); `eraseAllData()` clears tasks + archived + custom views + pinning + archive settings (theme untouched — convention 7).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreDataTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreDataTests {
    private func makeStore() throws -> (TaskStore, AppDatabase) {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let store = TaskStore(repository: GRDBTaskRepository(db),
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                              defaults: suite,
                              clock: { Date(timeIntervalSince1970: 1000) },
                              newID: { "imp-fixed" },
                              calendar: .current)
        return (store, db)
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.tasks.count != count && waited < 200 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: true, important: true,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func exportThenImportReplaceRoundTrips() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("a"))
        try await store.create(task("b"))
        try await waitForTasks(store, count: 2)
        let data = try store.exportJSON()
        try await store.importTasks(data, mode: .replace)
        try await waitForTasks(store, count: 2)
        #expect(Set(store.tasks.map(\.id)) == ["a", "b"])
    }
    @Test func importReplaceClearsExisting() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("old"))
        try await waitForTasks(store, count: 1)
        let payload = try TaskExport.encode(TaskExport(tasks: [task("fresh")],
                                                       exportedAt: Date(timeIntervalSince1970: 0)))
        try await store.importTasks(payload, mode: .replace)
        try await waitForTasks(store, count: 1)
        #expect(store.tasks.map(\.id) == ["fresh"])
    }
    @Test func importMergeRegeneratesCollidingId() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        let payload = try TaskExport.encode(TaskExport(tasks: [task("a")],
                                                       exportedAt: Date(timeIntervalSince1970: 0)))
        try await store.importTasks(payload, mode: .merge)
        try await waitForTasks(store, count: 2)
        #expect(Set(store.tasks.map(\.id)) == ["a", "imp-fixed"])   // colliding id regenerated
    }
    @Test func eraseAllDataClearsTasksAndPinsButNotTheme() async throws {
        let (store, _) = try makeStore()
        store.start()
        try await store.create(task("a"))
        try await waitForTasks(store, count: 1)
        store.pin("overdue")
        try await store.eraseAllData()
        try await waitForTasks(store, count: 0)
        #expect(store.tasks.isEmpty)
        #expect(store.pinnedSmartViewIds.isEmpty)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreDataTests` → FAIL (`exportJSON`/`importTasks`/`eraseAllData`/`ImportMode` not found).

- [ ] **Step 3: Edit `TaskStore.swift`.** Add a `// MARK: Data (export / import / reset)` section after the bulk operations:
```swift
    // MARK: Data (export / import / reset)

    public enum ImportMode: Sendable { case replace, merge }

    /// Serialize the live task snapshot to a `TaskExport` JSON payload (design-spec §3).
    public func exportJSON() throws -> Data {
        try TaskExport.encode(TaskExport(tasks: tasks, exportedAt: clock()))
    }

    /// Parse + persist an import. Replace clears all tasks then bulk-inserts (single
    /// transaction); Merge regenerates colliding ids + remaps references, then upserts each
    /// (stamping `updatedAt` via the clock). Limits + lenient decode live in `TaskImporter`.
    /// Returns the parse result so the UI can report skipped-count.
    /// NOTE (Phase 5): enqueue a sync op for each written task here.
    @discardableResult
    public func importTasks(_ data: Data, mode: ImportMode) async throws -> ImportResult {
        switch mode {
        case .replace:
            let result = try TaskImporter.replace(from: data)
            let now = clock()
            let stamped = result.tasks.map { task -> Task in
                var t = task; t.updatedAt = now; return t
            }
            try await repository.replaceAll(stamped)
            return result
        case .merge:
            let existing = Set(try await repository.fetchAll().map(\.id))
            let result = try TaskImporter.merge(from: data, existingIDs: existing, newID: { self.newID() })
            for task in result.tasks {
                var t = task; t.updatedAt = clock()
                try await repository.upsert(t)
            }
            return result
        }
    }

    /// Erase all app data EXCEPT the theme (design-spec §3 reset scope call): clears tasks,
    /// archived tasks, custom smart views, pinning, and archive settings. `appTheme` +
    /// `hasOnboarded` live in the App layer's `@AppStorage` and are intentionally untouched.
    public func eraseAllData() async throws {
        try await repository.replaceAll([])
        for archived in try await archiveRepository.fetchAll() {
            try await archiveRepository.deletePermanently(id: archived.id)
        }
        for view in try await smartViewRepository.fetchAll() {
            try await smartViewRepository.delete(id: view.id)
        }
        pinnedIDs = []
        defaults.removeObject(forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
        defaults.removeObject(forKey: AppGroupDefaults.Key.archiveAutoEnabled)
        defaults.removeObject(forKey: AppGroupDefaults.Key.archiveAfterDays)
    }
```
> **`newID` note:** Merge uses the store's injected `newID` (defaults to `Size.smartView` = 12-char nanoids — see 3b's type-consistency note; opaque ids, length is cosmetic). Tests inject `{ "imp-fixed" }`. If a regenerated id itself collides, `TaskImporter.merge` retries via the reserved-set loop (probe-verified).

> **`ImportResult` visibility:** `importTasks` returns `GSDModel.ImportResult`; `GSDStore` already `import GSDModel`, and `ImportResult`/`ImportMode` are public, so the App layer (Group D) can read `.skipped`.

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreDataTests` → PASS (4 tests). Re-run full `cd GSDKit && swift test` → green (additive; no signature change to `init`, so the three existing store-test constructors are unaffected).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreDataTests.swift && git commit -m "feat: add TaskStore exportJSON/importTasks/eraseAllData"`

> **Milestone after Group C:** export/import/erase are green via `swift test`. Run `cd GSDKit && swift test` (full) — Phase 0–3b + Group A + Group C all green — before the UI groups.

---

## Group B — Analytics Dashboard UI (App, Swift Charts, build-verify)

> Build-verified UI. The Dashboard is a pure render of `store.analytics(trendDays:)`. Maps **A29**. Lands AFTER Group A (the engine it consumes). The Dashboard nav entry (tab + sidebar) is added in B2 so the new tab never points at an unbuilt screen.

> Build command (run after each UI task; run `xcodegen generate` first whenever a NEW file was added so the regenerated `GSD.xcodeproj` includes it):
> ```
> cd /Users/vinnycarpenter/Projects/gsd-iosapp
> xcodegen generate
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet ; echo "exit $?"
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build -quiet ; echo "exit $?"
> ```
> Exit 0 = success (the `-quiet` banner may be suppressed). If a simulator name is unavailable, run `xcrun simctl list devices available`, pick an equivalent iPhone / iPad-Pro device, and report which. **Do NOT add a `DEVELOPMENT_TEAM` line to `GSD.xcodeproj`** (simulator builds work without it).

### Task B1: `DashboardView` (stat cards + charts + deadlines + empty state)

**Files:** Create `App/Dashboard/DashboardView.swift`

`import Charts`. Renders the summary: a stat-card grid, a 7/30/90-segmented completion-trend line chart, a quadrant donut, a top-tags bar, a time-by-quadrant bar, an upcoming-deadlines list (tap → editor), an overdue banner, and an empty state when there are no tasks. Mirrors `MatrixView`'s editor-sheet pattern (`@State editor: EditorRequest?` + `.sheet(item:)`).

- [ ] **Step 1:** Write `App/Dashboard/DashboardView.swift`:
```swift
import SwiftUI
import Charts
import GSDModel
import GSDStore

/// Analytics dashboard (product spec §6.15). A pure render of `store.analytics(trendDays:)`
/// — no computation here. The 7/30/90 segmented control only changes `trendDays`.
struct DashboardView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @State private var trendDays = 7
    @State private var editor: EditorRequest?

    private var summary: AnalyticsSummary { store.analytics(trendDays: trendDays) }

    var body: some View {
        NavigationStack {
            Group {
                if summary.totalCount == 0 {
                    ContentUnavailableView(String(localized: "No data yet"), systemImage: "chart.bar.xaxis",
                                           description: Text(String(localized: "Add and complete tasks to see your insights here.")))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if summary.overdueCount > 0 { overdueBanner(summary.overdueCount) }
                            statGrid(summary)
                            trendSection(summary)
                            quadrantDonut(summary)
                            topTagsChart(summary)
                            timeByQuadrantChart(summary)
                            upcomingDeadlines(summary)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle(String(localized: "Dashboard"))
            .toolbar { paletteButton(palette) }
            .sheet(item: $editor) { TaskEditorView(request: $0) }
        }
    }

    // MARK: sections

    private func overdueBanner(_ count: Int) -> some View {
        Label(String(localized: "\(count) overdue"), systemImage: "exclamationmark.triangle.fill")
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.red, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel(String(localized: "\(count) overdue tasks"))
    }

    private func statGrid(_ s: AnalyticsSummary) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statCard(String(localized: "Active"), "\(s.activeCount)", "tray.full")
            statCard(String(localized: "Completed"), "\(s.completedCount)", "checkmark.circle")
            statCard(String(localized: "Completion"), "\(Int((s.completionRate * 100).rounded()))%", "percent")
            statCard(String(localized: "Streak"), String(localized: "\(s.activeStreak) days"), "flame")
            statCard(String(localized: "Best streak"), String(localized: "\(s.longestStreak) days"), "trophy")
            statCard(String(localized: "Tracked"), TimeTracking.format(minutes: s.totalTrackedMinutes), "clock")
        }
    }

    private func statCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.serif(.title2)).fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "\(title): \(value)"))
    }

    private func trendSection(_ s: AnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(localized: "Completion Trend")).font(.headline)
                Spacer()
                Picker(String(localized: "Range"), selection: $trendDays) {
                    Text(String(localized: "7d")).tag(7)
                    Text(String(localized: "30d")).tag(30)
                    Text(String(localized: "90d")).tag(90)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            Chart {
                ForEach(s.trend) { point in
                    LineMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(String(localized: "Completed"), point.completed),
                             series: .value(String(localized: "Series"), String(localized: "Completed")))
                    .foregroundStyle(.green)
                    LineMark(x: .value(String(localized: "Day"), point.date),
                             y: .value(String(localized: "Created"), point.created),
                             series: .value(String(localized: "Series"), String(localized: "Created")))
                    .foregroundStyle(.blue)
                }
            }
            .frame(height: 200)
            .chartForegroundStyleScale([String(localized: "Completed"): Color.green,
                                        String(localized: "Created"): Color.blue])
            .accessibilityLabel(String(localized: "Completion trend over \(trendDays) days"))
        }
    }

    private func quadrantDonut(_ s: AnalyticsSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "By Quadrant")).font(.headline)
            Chart(s.quadrantStats.filter { $0.total > 0 }) { stat in
                SectorMark(angle: .value(String(localized: "Tasks"), stat.total), innerRadius: .ratio(0.6))
                    .foregroundStyle(by: .value(String(localized: "Quadrant"), stat.quadrant.title))
            }
            .frame(height: 220)
            .accessibilityLabel(String(localized: "Task distribution across the four quadrants"))
        }
    }

    private func topTagsChart(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.topTags.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Top Tags")).font(.headline)
                    Chart(s.topTags) { stat in
                        BarMark(x: .value(String(localized: "Count"), stat.count),
                                y: .value(String(localized: "Tag"), stat.tag))
                    }
                    .frame(height: CGFloat(s.topTags.count) * 32 + 24)
                    .accessibilityLabel(String(localized: "Most-used tags by task count"))
                }
            }
        }
    }

    private func timeByQuadrantChart(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.totalTrackedMinutes == 0 { EmptyView() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Time by Quadrant")).font(.headline)
                    Chart(s.timeByQuadrant) { stat in
                        BarMark(x: .value(String(localized: "Quadrant"), stat.quadrant.title),
                                y: .value(String(localized: "Minutes"), stat.minutes))
                        .foregroundStyle(by: .value(String(localized: "Quadrant"), stat.quadrant.title))
                    }
                    .frame(height: 200)
                    .accessibilityLabel(String(localized: "Tracked minutes per quadrant"))
                }
            }
        }
    }

    private func upcomingDeadlines(_ s: AnalyticsSummary) -> some View {
        Group {
            if s.upcomingDeadlines.isEmpty { EmptyView() } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(localized: "Upcoming Deadlines")).font(.headline)
                    ForEach(s.upcomingDeadlines) { task in
                        Button { editor = .edit(task) } label: {
                            HStack {
                                Text(task.title)
                                Spacer()
                                if let due = task.dueDate {
                                    Text(due, style: .date).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 6)
                        Divider()
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Build** (new file → `xcodegen generate` first) both simulators → exit 0. (No nav entry yet; the build just confirms `DashboardView` + Charts compile. If `chartForegroundStyleScale`/`SectorMark` differ on the toolchain, fix to the compiler-accepted form and note it.)
- [ ] **Step 3: Commit:** `git add App/Dashboard/DashboardView.swift GSD.xcodeproj && git commit -m "feat: add Swift Charts DashboardView rendering AnalyticsSummary"`

### Task B2: Dashboard nav entry (iPhone tab + iPad sidebar + palette)

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/Palette/CommandPaletteView.swift`

Add Dashboard to the iPhone `TabView` (tag 2) and the iPad sidebar, plus a `PaletteDestination.dashboard` + `RegularItem.dashboard` nav target. **Settings is NOT added here** (Group E) — this task only wires Dashboard, so each commit leaves the app building with every tab pointing at a real screen.

- [ ] **Step 1: Edit `App/Palette/CommandPaletteView.swift`.** Add `dashboard` to both enums and a nav row:
```swift
enum PaletteDestination { case matrix, browse, archive, dashboard }
```
```swift
enum RegularItem: Hashable { case matrix, archive, dashboard, smartView(String) }
```
In `navResults`, add the Dashboard row (insert after the Matrix row):
```swift
        [(String(localized: "Matrix"), "square.grid.2x2", .navigate(.matrix)),
         (String(localized: "Dashboard"), "chart.bar.xaxis", .navigate(.dashboard)),
         (String(localized: "Browse"), "line.3.horizontal.decrease.circle", .navigate(.browse)),
         (String(localized: "Archive"), "archivebox", .navigate(.archive))]
            .filter { match($0.0) }
```

- [ ] **Step 2: Edit `App/ContentView.swift`.** Add the Dashboard tab to the compact `TabView` (after Browse, `.tag(2)`):
```swift
            TabView(selection: $palette.compactTab) {
                MatrixView()
                    .tabItem { Label(String(localized: "Matrix"), systemImage: "square.grid.2x2") }
                    .tag(0)
                SmartViewListView()
                    .tabItem { Label(String(localized: "Browse"), systemImage: "line.3.horizontal.decrease.circle") }
                    .tag(1)
                DashboardView()
                    .tabItem { Label(String(localized: "Dashboard"), systemImage: "chart.bar.xaxis") }
                    .tag(2)
            }
```
Extend `navigate(to:)` to handle `.dashboard` in both idioms (the compact Dashboard tab is tag 2):
```swift
    private func navigate(to dest: PaletteDestination) {
        if sizeClass == .compact {
            switch dest {
            case .matrix: palette.compactTab = 0
            case .browse: palette.compactTab = 1; palette.browsePath = []
            case .archive: palette.compactTab = 1; palette.browsePath = [.archive]
            case .dashboard: palette.compactTab = 2
            }
        } else {
            switch dest {
            case .matrix: palette.regularSelection = .matrix
            case .browse: break   // iPad has no Browse tab; the sidebar is always visible
            case .archive: palette.regularSelection = .archive
            case .dashboard: palette.regularSelection = .dashboard
            }
        }
    }
```
In `RegularRootView`, add a Dashboard sidebar item (after the Archive `Label`) and a detail case. Add the label inside the top `List`:
```swift
                Label(String(localized: "Matrix"), systemImage: "square.grid.2x2").tag(RegularItem.matrix)
                Label(String(localized: "Dashboard"), systemImage: "chart.bar.xaxis").tag(RegularItem.dashboard)
                Label(String(localized: "Archive"), systemImage: "archivebox").tag(RegularItem.archive)
```
And add the detail branch (in the `switch palette.regularSelection`):
```swift
            case .dashboard:
                DashboardView()
```

- [ ] **Step 3: Build** both simulators → exit 0. Launch the iPhone sim: a 3rd tab "Dashboard" appears (Matrix · Browse · Dashboard) and shows the empty state (or charts if tasks exist). Launch the iPad sim: the sidebar has a Dashboard row; selecting it shows the dashboard in the detail column. ⌘K → "Dashboard" navigates. Capture a Dashboard screenshot on each idiom.
- [ ] **Step 4: Commit:** `git add App/ContentView.swift App/Palette/CommandPaletteView.swift GSD.xcodeproj && git commit -m "feat: add Dashboard tab (iPhone) and sidebar entry (iPad) + palette target"`

> **Milestone after Group B:** the Dashboard is reachable + renders on both idioms; `DashboardView` is a pure render of the tested engine; both simulators build. (Settings tab/sidebar lands in Group E — the iPhone TabView is Matrix · Browse · Dashboard for now, a valid 3-tab state.)

---

## Group D — Import/Export + Reset UI (App, build-verify)

> Build-verified UI. A self-contained `DataStorageView` that compiles standalone (Group E's `SettingsView` embeds it). Maps **A30/A31/A32** (UI side). Uses `ShareLink` (export), `.fileImporter` (import, Replace/Merge picker), and a type-"RESET" confirmation (Erase All). All consume the Group-C store methods. **Confirm-at-build** for `ShareLink`/`FileDocument`/`.fileImporter`.

### Task D1: `DataStorageView` (export / import / reset)

**Files:** Create `App/Settings/DataStorageView.swift`

A `Form`-section view (so it slots into `SettingsView`'s `Form` as a `Section`, AND works standalone in a `NavigationStack` for build verification). Export uses `ShareLink` over a `TaskExportDocument: FileDocument`. Import uses `.fileImporter` then an action sheet picking Replace vs Merge. Erase uses an alert with a "RESET" text field + an "Export first" affordance.

- [ ] **Step 1:** Write `App/Settings/DataStorageView.swift`:
```swift
import SwiftUI
import UniformTypeIdentifiers
import GSDModel
import GSDStore

/// A `FileDocument` wrapping the export JSON so `ShareLink` can offer it as a `.json` file.
/// Read-only (export only); `init(configuration:)` is required by the protocol but unused.
struct TaskExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileContents: data)
    }
}

/// Data & Storage settings: export (ShareLink), import (.fileImporter → Replace/Merge),
/// and Erase All (type-RESET + export-first prompt). Rendered as `Form` sections so it can
/// be embedded in `SettingsView` or shown standalone. All actions go through the store.
struct DataStorageView: View {
    @Environment(TaskStore.self) private var store

    @State private var exportDocument: TaskExportDocument?
    @State private var showImporter = false
    @State private var pendingImportData: Data?
    @State private var showModePicker = false
    @State private var showEraseAlert = false
    @State private var resetConfirmText = ""
    @State private var statusMessage: String?

    var body: some View {
        Group {
            Section(String(localized: "Export")) {
                if let exportDocument {
                    ShareLink(item: exportDocument, preview: SharePreview(String(localized: "GSD Tasks"))) {
                        Label(String(localized: "Share Export File"), systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    exportDocument = (try? store.exportJSON()).map(TaskExportDocument.init(data:))
                } label: {
                    Label(String(localized: "Prepare Export"), systemImage: "doc.badge.arrow.up")
                }
            }

            Section(String(localized: "Import")) {
                Button {
                    showImporter = true
                } label: {
                    Label(String(localized: "Import Tasks…"), systemImage: "square.and.arrow.down")
                }
                if let statusMessage {
                    Text(statusMessage).font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                Button(role: .destructive) {
                    resetConfirmText = ""
                    showEraseAlert = true
                } label: {
                    Label(String(localized: "Erase All Data"), systemImage: "trash")
                }
            } footer: {
                Text(String(localized: "Erasing removes all tasks, archived items, and custom views. Your appearance settings are kept. Export first if you want a backup."))
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.json]) { result in
            handleImportPick(result)
        }
        .confirmationDialog(String(localized: "Import Mode"), isPresented: $showModePicker, titleVisibility: .visible) {
            Button(String(localized: "Merge (keep existing)")) { runImport(mode: .merge) }
            Button(String(localized: "Replace (erase existing)"), role: .destructive) { runImport(mode: .replace) }
            Button(String(localized: "Cancel"), role: .cancel) { pendingImportData = nil }
        } message: {
            Text(String(localized: "Merge keeps your current tasks and adds the imported ones. Replace deletes your current tasks first."))
        }
        .alert(String(localized: "Erase All Data"), isPresented: $showEraseAlert) {
            TextField(String(localized: "Type RESET to confirm"), text: $resetConfirmText)
            Button(String(localized: "Erase"), role: .destructive) {
                guard resetConfirmText == "RESET" else { return }
                _Concurrency.Task {
                    try? await store.eraseAllData()
                    statusMessage = String(localized: "All data erased.")
                }
            }
            .disabled(resetConfirmText != "RESET")
            Button(String(localized: "Cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "This cannot be undone. Type RESET to confirm. Consider exporting first."))
        }
    }

    private func handleImportPick(_ result: Result<URL, Error>) {
        guard case let .success(url) = result else { return }
        // Security-scoped resource: a file picked outside the sandbox must be opened
        // within a start/stop access pair.
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            statusMessage = String(localized: "Couldn’t read that file."); return
        }
        pendingImportData = data
        showModePicker = true
    }

    private func runImport(mode: TaskStore.ImportMode) {
        guard let data = pendingImportData else { return }
        pendingImportData = nil
        _Concurrency.Task {
            do {
                let result = try await store.importTasks(data, mode: mode)
                statusMessage = result.skipped == 0
                    ? String(localized: "Imported \(result.tasks.count) tasks.")
                    : String(localized: "Imported \(result.tasks.count) tasks (\(result.skipped) skipped).")
            } catch {
                statusMessage = String(localized: "Import failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Standalone host so the view build-verifies without `SettingsView` (Group E embeds the
/// sections directly into its own Form). Compiled by the app; not a throwaway.
struct DataStorageScreen: View {
    var body: some View {
        NavigationStack {
            Form { DataStorageView() }
                .navigationTitle(String(localized: "Data & Storage"))
        }
    }
}
```

- [ ] **Step 2: Build** (new file → `xcodegen generate` first) both simulators → exit 0. If `ShareLink(item:preview:)` over a `FileDocument` needs a different initializer on the toolchain (e.g. exporting via `.fileExporter` instead), adjust to the compiler-accepted form and note it. (`.json` is a built-in `UTType`; `UniformTypeIdentifiers` import is required.)
- [ ] **Step 3:** Temporarily reference `DataStorageScreen` from a build-only call site to confirm it renders — the cleanest is to NOT wire it into nav yet (Group E does that) but ensure it compiles. The standalone `DataStorageScreen` is compiled because it is in the App target; no extra wiring needed for the build to cover it.
- [ ] **Step 4: Commit:** `git add App/Settings/DataStorageView.swift GSD.xcodeproj && git commit -m "feat: add Data & Storage view (ShareLink export, fileImporter import, RESET erase)"`

> **Milestone after Group D:** export/import/reset UI compiles on both simulators and consumes the tested Group-C store methods. It is reachable from Settings in Group E.

---

## Group E — Onboarding + Settings + nav entry (App, build-verify)

> Build-verified UI. `OnboardingView` (first-run, gated by `hasOnboarded`), `SettingsView` (Appearance/Archive/Data & Storage/About — embedding Group D), the Settings tab/sidebar entry, and re-show-onboarding from About. Maps **A33** (Settings) + **A34** (Onboarding). Lands last (it embeds Group D + adds the final nav entry → the iPhone TabView reaches its 4-tab end state).

### Task E1: `OnboardingView` (first-run, paged, skippable)

**Files:** Create `App/Onboarding/OnboardingView.swift`

A paged `TabView(.page)` intro with a Skip + a final "Get Started". On dismiss it sets `hasOnboarded = true`. Re-showable (Group E3) by flipping the flag back. Takes an `onFinish` closure so the presenter (the App) owns the flag.

- [ ] **Step 1:** Write `App/Onboarding/OnboardingView.swift`:
```swift
import SwiftUI

/// First-run onboarding (design-spec §3): a skippable, paged intro. The `hasOnboarded`
/// flag is owned by the presenter; this view just calls `onFinish` when done/skipped.
struct OnboardingView: View {
    var onFinish: () -> Void
    @State private var page = 0

    private struct Page: Identifiable {
        let id = UUID(); let icon: String; let title: String; let body: String
    }
    private let pages: [Page] = [
        .init(icon: "square.grid.2x2",
              title: String(localized: "Prioritize with the Matrix"),
              body: String(localized: "Sort tasks by urgency and importance across four quadrants.")),
        .init(icon: "line.3.horizontal.decrease.circle",
              title: String(localized: "Focus with Smart Views"),
              body: String(localized: "Browse built-in and custom views to see exactly what matters now.")),
        .init(icon: "chart.bar.xaxis",
              title: String(localized: "Track your progress"),
              body: String(localized: "The dashboard shows streaks, trends, and where your time goes.")),
    ]

    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(String(localized: "Skip"), action: onFinish)
                    .padding()
            }
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.element.id) { index, p in
                    VStack(spacing: 20) {
                        Image(systemName: p.icon)
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                        Text(p.title).font(.serif(.title)).multilineTextAlignment(.center)
                        Text(p.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(40)
                    .tag(index)
                }
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            Button(action: advance) {
                Text(page == pages.count - 1 ? String(localized: "Get Started") : String(localized: "Next"))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
    }

    private func advance() {
        if page < pages.count - 1 { withAnimation { page += 1 } } else { onFinish() }
    }
}
```

- [ ] **Step 2: Build** (new file → `xcodegen generate` first) both simulators → exit 0.
- [ ] **Step 3: Commit:** `git add App/Onboarding/OnboardingView.swift GSD.xcodeproj && git commit -m "feat: add paged skippable OnboardingView"`

### Task E2: `SettingsView` (Appearance / Archive / Data & Storage / About)

**Files:** Create `App/Settings/SettingsView.swift`

A `Form`. Appearance = theme picker (`AppTheme`) + show-completed toggle (the same `@AppStorage` keys the rest of the app reads). Archive = auto-archive toggle + 30/60/90 picker + "Archive now" (reuses `store.archiveSettings` + `runAutoArchiveSweep()`). Data & Storage = embeds Group D's `DataStorageView`. About = version, privacy summary, links, re-show-onboarding. **NO Notifications/Cloud Sync sections.**

- [ ] **Step 1:** Write `App/Settings/SettingsView.swift`:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// The full Settings screen (design-spec §3 scope call): Appearance, Archive, Data &
/// Storage, About. Notifications + Cloud Sync are intentionally absent (Phase 4/5 — the
/// project ships no control that does nothing). `reshowOnboarding` flips the App-owned flag.
struct SettingsView: View {
    @Environment(TaskStore.self) private var store
    @Environment(PaletteController.self) private var palette
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false

    /// Local mirror of the store's archive settings (UserDefaults-backed); writes flush back.
    @State private var archiveSettings: ArchiveSettings = .init()
    @State private var archiveStatus: String?

    var body: some View {
        NavigationStack {
            Form {
                appearanceSection
                archiveSection
                DataStorageView()          // Group D sections
                aboutSection
            }
            .navigationTitle(String(localized: "Settings"))
            .toolbar { paletteButton(palette) }
            .onAppear { archiveSettings = store.archiveSettings }
        }
    }

    private var appearanceSection: some View {
        Section(String(localized: "Appearance")) {
            Picker(String(localized: "Theme"), selection: $themeRaw) {
                ForEach(AppTheme.allCases) { theme in Text(theme.label).tag(theme.rawValue) }
            }
            Toggle(String(localized: "Show Completed Tasks"), isOn: $showCompleted)
        }
    }

    private var archiveSection: some View {
        Section(String(localized: "Archive")) {
            Toggle(String(localized: "Auto-archive completed tasks"), isOn: Binding(
                get: { archiveSettings.autoEnabled },
                set: { archiveSettings.autoEnabled = $0; store.archiveSettings = archiveSettings }
            ))
            if archiveSettings.autoEnabled {
                Picker(String(localized: "Archive after"), selection: Binding(
                    get: { archiveSettings.afterDays },
                    set: { archiveSettings.afterDays = $0; store.archiveSettings = archiveSettings }
                )) {
                    ForEach(ArchiveSettings.allowedDays, id: \.self) { d in
                        Text(String(localized: "\(d) days")).tag(d)
                    }
                }
            }
            Button {
                _Concurrency.Task {
                    try? await store.runAutoArchiveSweep()
                    archiveStatus = String(localized: "Archive sweep complete.")
                }
            } label: {
                Label(String(localized: "Archive Now"), systemImage: "archivebox")
            }
            if let archiveStatus {
                Text(archiveStatus).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var aboutSection: some View {
        Section(String(localized: "About")) {
            LabeledContent(String(localized: "Version"), value: appVersion)
            Text(String(localized: "GSD stores all data locally on your device. Nothing is sent to a server."))
                .font(.footnote).foregroundStyle(.secondary)
            Link(String(localized: "Privacy Policy"), destination: URL(string: "https://vinny.dev/gsd/privacy")!)
            Button {
                hasOnboarded = false       // App root re-presents onboarding on the flag change
            } label: {
                Label(String(localized: "Show Onboarding Again"), systemImage: "sparkles")
            }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
```

- [ ] **Step 2: Build** (new file → `xcodegen generate` first) both simulators → exit 0.
- [ ] **Step 3: Commit:** `git add App/Settings/SettingsView.swift GSD.xcodeproj && git commit -m "feat: add SettingsView (Appearance/Archive/Data & Storage/About)"`

### Task E3: Settings nav entry + onboarding gate at the app root

**Files:**
- Modify: `App/ContentView.swift`
- Modify: `App/Palette/CommandPaletteView.swift`
- Modify: `App/GSDApp.swift`

Add Settings to the iPhone TabView (tag 3 → final 4-tab state) + the iPad sidebar + a palette target, and gate onboarding behind `hasOnboarded` at the app root.

- [ ] **Step 1: Edit `App/Palette/CommandPaletteView.swift`.** Add `settings` to both enums and a nav row:
```swift
enum PaletteDestination { case matrix, browse, archive, dashboard, settings }
```
```swift
enum RegularItem: Hashable { case matrix, archive, dashboard, settings, smartView(String) }
```
Append the Settings row to `navResults`:
```swift
         (String(localized: "Settings"), "gearshape", .navigate(.settings))]
            .filter { match($0.0) }
```
(Place it as the last element of the array literal before `.filter`.)

- [ ] **Step 2: Edit `App/ContentView.swift`.** Add the Settings tab (after Dashboard, `.tag(3)`):
```swift
                DashboardView()
                    .tabItem { Label(String(localized: "Dashboard"), systemImage: "chart.bar.xaxis") }
                    .tag(2)
                SettingsView()
                    .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                    .tag(3)
```
Extend `navigate(to:)` for `.settings` (compact tab 3; iPad selection):
```swift
            case .dashboard: palette.compactTab = 2
            case .settings: palette.compactTab = 3
```
and in the iPad branch:
```swift
            case .dashboard: palette.regularSelection = .dashboard
            case .settings: palette.regularSelection = .settings
```
In `RegularRootView`, add the sidebar item (after Dashboard) and the detail branch:
```swift
                Label(String(localized: "Settings"), systemImage: "gearshape").tag(RegularItem.settings)
```
```swift
            case .settings:
                SettingsView()
```

- [ ] **Step 3: Edit `App/GSDApp.swift`** to gate onboarding. Add the flag + a full-screen cover:
```swift
import SwiftUI
import GSDStore

@main
struct GSDApp: App {
    @State private var store: TaskStore
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue
    @AppStorage("hasOnboarded", store: .shared) private var hasOnboarded = false

    init() {
        // The local store is the app's source of truth; failure to open it is unrecoverable.
        let database = try! AppDatabase.live()
        _store = State(initialValue: TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database)
        ))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme ?? nil)
                .task {
                    store.start()
                    try? await store.runAutoArchiveSweep()
                }
                .fullScreenCover(isPresented: Binding(
                    get: { !hasOnboarded },
                    set: { presenting in if !presenting { hasOnboarded = true } }
                )) {
                    OnboardingView { hasOnboarded = true }
                }
        }
    }
}
```

- [ ] **Step 4: Build** both simulators → exit 0. Launch fresh (reset the sim / delete the app first so `hasOnboarded` is false): onboarding appears, Skip/Get Started dismisses it and sets the flag. Relaunch: it does NOT reappear. iPhone now shows 4 tabs (Matrix · Browse · Dashboard · Settings); Settings → About → "Show Onboarding Again" re-presents it. iPad sidebar shows Dashboard + Settings; selecting Settings shows the screen. ⌘K → "Settings" navigates. Capture: onboarding, Settings (both idioms).
- [ ] **Step 5: Commit:** `git add App/ContentView.swift App/Palette/CommandPaletteView.swift App/GSDApp.swift GSD.xcodeproj && git commit -m "feat: add Settings tab/sidebar entry and first-run onboarding gate"`

> **Milestone after Group E:** the iPhone TabView is Matrix · Browse · Dashboard · Settings (4 tabs); the iPad sidebar has Matrix · Dashboard · Archive · Settings + Smart Views; onboarding gates first run and is re-showable; both simulators build + launch.

---

## Phase 3c — Definition of Done

Mapped to the spec's acceptance criteria (A28–A34).

- [ ] **A28 — AnalyticsEngine.** Every §6.15 metric computed correctly under a pinned calendar/now: counts + completion-rate (div-by-zero → 0), active streak (incl. lenient today-with-zero) + longest + last-7, quadrant distribution + per-quadrant completion (always 4, Q1→Q4), top-tags, deadline counts + upcoming list, completion trend at 7/30/90 (half-open buckets), time-tracking summary; store delegation over the live snapshot with the injected clock. *Tests:* `AnalyticsEngineTests` (13), `TaskStoreAnalyticsTests` (1). *Probes:* streak 10/10, trend 13/13.
- [ ] **A29 — Dashboard.** Renders all charts + stat cards from `AnalyticsSummary`; 7/30/90 trend toggle (changes `trendDays` only); overdue banner; empty state; upcoming-deadline tap opens the editor. *Build:* both destinations exit 0 (B1, B2). Pure render — no logic in the view.
- [ ] **A30 — Export.** `exportJSON()` produces `{tasks, exportedAt, version:1}` JSON via the fractional-seconds codec; round-trips through import-replace to the same set. *Tests:* `TaskExportTests` (4), `TaskStoreDataTests.exportThenImportReplaceRoundTrips`.
- [ ] **A31 — Import.** Replace clears+inserts (single transaction via `replaceAll`); Merge regenerates colliding ids + remaps `dependencies`/`parentTaskId` (two-phase, forward refs); lenient decode (custom `Task.init(from:)`, C0) fills defaults for missing keys + ignores unknown keys + skips/counts bad tasks; limits enforced (>10k, >10MB). *Tests:* `TaskLenientDecodeTests` (4), `TaskImporterTests` (8), `TaskRepositoryReplaceTests` (2), `TaskStoreDataTests` (merge/replace). *Probes:* merge 12/12, task_lenient 9/9.
- [ ] **A32 — Reset.** Type-RESET-to-confirm + export-first prompt; theme (+`hasOnboarded`) preserved; clears tasks + archived + custom views + pinning + archive settings. *Tests:* `TaskStoreDataTests.eraseAllDataClearsTasksAndPinsButNotTheme`. *Build:* D1.
- [ ] **A33 — Settings.** Appearance/Archive/Data & Storage/About sections work; Notifications/Cloud Sync NOT present; reachable via tab (iPhone) + sidebar (iPad). *Build:* E2, E3 exit 0.
- [ ] **A34 — Onboarding.** First-run skippable paged flow; re-showable from About; `hasOnboarded` flag gates it. *Build:* E1, E3 (fresh-launch verification).
- [ ] **Coverage.** `cd GSDKit && swift test` fully green, sub-second for all new logic; both simulators build + launch (smoke). One commit per task. No `DEVELOPMENT_TEAM` committed.

---

## Self-review (spec coverage · placeholders · type consistency)

**Spec coverage (§4–§6, A28–A34):** AnalyticsEngine all §6.15 metrics + boundaries (A2, probe-verified) → A28 ✔; DashboardView charts/cards/toggle/banner/empty/tap-to-edit (B1) + nav entry (B2) → A29 ✔; TaskExport envelope + round-trip (C1, C4) → A30 ✔; lenient `Task.init(from:)` (C0, probe-verified — closes the synthesized-Codable trap) + TaskImporter two-phase merge remap + limits (C2) + replaceAll (C3) + store import (C4) → A31 ✔; eraseAllData theme-preserving (C4) + type-RESET/export-first UI (D1) → A32 ✔; SettingsView 4 sections, no Notifications/Cloud-Sync, tab+sidebar (E2, E3) → A33 ✔; OnboardingView first-run/skippable/re-showable + hasOnboarded gate (E1, E3) → A34 ✔. Cross-cutting nav: iPhone TabView Matrix·Browse·Dashboard·Settings (B2 adds Dashboard, E3 adds Settings); iPad sidebar +Dashboard +Settings (B2, E3) ✔. Sequencing A → C → B → D → E lands logic (A, C) before consuming UI (B, D, E) ✔. Deferred items honored: sync-enqueue = Phase-5 TODO comment; NO Notifications/Cloud Sync sections ✔.

**Placeholder scan:** every code step contains complete, compilable Swift — no `TBD`/`…`/"similar to". Test files give full suites with exact `swift test --filter` commands + expected pass counts. UI tasks give full build commands. The one "confirm at build" caveats (Charts API form, `ShareLink`-over-`FileDocument`) are explicit adjust-and-note instructions, not placeholders.

**Type consistency:** `AnalyticsSummary` (+ nested `TrendPoint`/`QuadrantStat`/`TagStat`/`TimeByQuadrant`) and `AnalyticsEngine.compute(tasks:now:calendar:trendDays:)` used consistently (A1→A2→A3→B1). `TaskExport(tasks:exportedAt:version:)` + `encode`/`decode`/`decoder()` (C1→C2→C4→D1). `TaskImporter.replace(from:)`/`merge(from:existingIDs:newID:)`/`ImportResult(tasks:skipped:)`/`ImportError`/`maxImportTasks`/`maxImportBytes` (C2→C4→D1). `TaskRepository.replaceAll(_:)` (C3→C4). `TaskStore.analytics(trendDays:)`/`exportJSON()`/`importTasks(_:mode:)`/`ImportMode`/`eraseAllData()` (A3, C4→B1, D1, E2). App refs match real Phase-3b APIs: `PaletteController.compactTab`/`regularSelection`/`browsePath`, `RegularItem`/`PaletteDestination` (extended consistently in B2 + E3), `paletteButton(_:)`, `EditorRequest.edit`, `TaskEditorView(request:)`, `AppTheme.allCases`/`.label`/`.colorScheme`/`Font.serif(_:)`, `store.archiveSettings`/`runAutoArchiveSweep()`/`ArchiveSettings.allowedDays`, `@AppStorage(..., store: .shared)` (App-Group). `String(localized:)` in GSDModel is Foundation-provided (precedent: `TimeTracking.format`). `_Concurrency.Task` used in all app concurrency (never bare `Task {}`). New `.swift` files trigger `xcodegen generate` before build (B1, B2 enum-only edits no new file but ContentView/Palette are existing; D1, E1, E2 new files; E3 edits existing — generate run noted per UI task). No `DEVELOPMENT_TEAM` added to the project.
