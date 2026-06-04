# Phase 3a — Filtering & Navigation Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure `FilterCriteria` filtering engine, the 9 built-in smart views (in-code constants), and the TabView/sidebar navigation shell that makes them usable — no new database tables.

**Architecture:** Correctness-critical filtering lands as a pure, dependency-free unit in `GSDModel` (`FilterCriteria` + `TaskFilter`), red→green→refactor'd with Swift Testing and an injected `Calendar`/`now` (date predicates probe-verified). The `@MainActor @Observable TaskStore` grows a derived `tasks(matching:)` query. The app gains a navigation shell — iPhone `TabView` (Matrix · Browse) and iPad `NavigationSplitView` sidebar — plus a `SmartViewListView` (Browse) and a `FilteredTaskListView` that reuses an extracted `TaskListRow`.

**Tech Stack:** Swift 6 (toolchain Apple Swift 6.x), SwiftUI (Observation, `TabView`, `NavigationSplitView`, `NavigationStack`), GSDKit (`GSDModel` zero-deps + `GSDStore` over GRDB), Swift Testing (`@Test`/`#expect`) for logic, `xcodebuild` for the app.

**Builds on (Phases 0–2, committed on `main` at tag `phase-2-task-depth`):**
- `GSDModel`: `Task` (incl. `dueDate`, `recurrence`, `tags`, `subtasks`, `completed`, `completedAt`, `createdAt`, `dependencies`; init has defaults for optional fields — the short form `Task(id:title:urgent:important:completed:createdAt:updatedAt:dependencies:)` compiles), `Subtask` (`.title`, `.completed`), `Quadrant` (`String` enum, `init(urgent:important:)`, `CaseIterable`, `Hashable`, Q1→Q4 order), `RecurrenceType` (`none`/`daily`/`weekly`/`monthly`, `CaseIterable`, `Equatable`), `DependencyGraph(tasks:)` with `uncompletedBlockers(of:) -> [Task]`.
- `GSDStore`: `TaskStore` (`@MainActor @Observable`; observable `tasks: [Task]`, `private let clock: @Sendable () -> Date`, `private let calendar: Calendar`, `tasks(in:showCompleted:)`).
- App: `MatrixView` (NavigationStack + List + `QuadrantSection`, owns `@State editor: EditorRequest?` + `.sheet(item:) { TaskEditorView(request:) }` + `ConfettiView(trigger:)`), `MatrixGridView` (iPad grid), `QuadrantSection`/`QuadrantCell`, `TaskCardView(task:now:blockedByCount:blockingCount:)`, `TaskActions(store:onCompleted:)` (`toggle`/`delete`/`move`/`snooze`/`startTimer`/`stopTimer`), `EditorRequest` (`.edit(Task)`/`.new(Quadrant, prefill:)`, `Identifiable`), `QuadrantStyle.accent(_:)`/`.symbol(_:)`, `ContentView` (compact → `MatrixView`, regular → `MatrixGridView`).

**Reference:** design spec `docs/specs/2026-05-30-phase-3a-filtering-navigation.md`; product spec `spec.md` (§5.6 SmartView, §5.9 FilterCriteria, §6.13 smart views, §6.14 search note).

---

## Architecture conventions locked by this plan (read first)

1. **`GSDModel` stays zero-dependency.** `FilterCriteria.swift`, `TaskFilter.swift`, and the smart-view constants link only `Foundation`. No GRDB, no SwiftUI. `String(localized:)` IS available from Foundation (already used by `TimeTracking.format`).
2. **`GSDModel.Task` shadows Swift Concurrency's `Task`.** Use bare `Task` only as the domain model type. Group A/B have no concurrency; in app code use `_Concurrency.Task { }` (never bare `Task { }`) — `TaskActions` already does.
3. **Inject time.** `TaskFilter.apply` takes `now: Date` and `calendar: Calendar`; no `Date()`/`Calendar.current` inside. The store passes its injected `clock()`/`calendar`. Tests pin a fixed UTC gregorian calendar + fixed `now`. **Date predicates are PROBE-VERIFIED** (see the note after Task A1).
4. **Filtering is read-only/derived.** `TaskFilter`/`tasks(matching:)` never mutate; the store stays the only mutation path.
5. **`Bool` filter flags: `false` = "don't constrain," not "must be false."** Only `true` flags add a predicate.
6. **`readyToWork` needs the FULL task set.** Build `DependencyGraph(tasks: tasks)` from the unfiltered input; a blocker excluded by another criterion must still block.
7. **Accessibility + localization (carried):** Dynamic Type, VoiceOver labels, `String(localized:)` for all UI copy, ≥44pt targets.
8. **SwiftUI navigation APIs are "confirm at build."** They can't be `/tmp`-probed; the adaptive `TabView`(compact)/`NavigationSplitView`(regular) root and the sidebar-selection→detail binding are verified via `xcodebuild` on both simulators (flag at build if they don't compile as written).

---

## Scope calls (from the approved spec; do not relitigate)

- **Lean data layer:** no new tables in 3a; the 9 built-ins are in-code constants. Custom-view CRUD/pinning/`smartViews` table/`AppPreferences` + archive + search-UI/⌘K palette + bulk + analytics + import/export are 3b/3c.
- **Complete pipeline now:** all §5.9 fields implemented + tested; `searchQuery`/`dueDateRange` are built but only *surfaced* in 3b.
- **TabView = Matrix + Browse only** (no Settings tab in 3a — no Settings screen exists yet; that's 3c). iPad gains the sidebar.
- **Result sort (§5 of spec):** `status == .completed` → `completedAt` desc (nil last); else → `dueDate` asc (nil last), tie-break `createdAt` desc.

---

## File Structure

```
GSDKit/Sources/GSDModel/
├─ FilterCriteria.swift        # predicate bundle (§5.9) + Status/DateRange
├─ TaskFilter.swift            # pure apply(_:to:now:calendar:) + sort
├─ SmartView.swift             # SmartView value type + BuiltInSmartViews (9 constants)
└─ (Phase 0–2 files unchanged)

GSDKit/Tests/GSDModelTests/
├─ TaskFilterTests.swift       # every criterion, AND, dates, deps, search, sort
└─ BuiltInSmartViewsTests.swift

GSDKit/Sources/GSDStore/
└─ TaskStore.swift             # MODIFIED: + tasks(matching:)

GSDKit/Tests/GSDStoreTests/
└─ TaskStoreFilterTests.swift  # new

App/
├─ ContentView.swift           # MODIFIED: adaptive root → TabView / NavigationSplitView
├─ Matrix/
│  ├─ TaskListRow.swift        # NEW: extracted reusable List row (TimelineView+card+swipes+menu)
│  └─ QuadrantSection.swift    # MODIFIED: use TaskListRow
└─ Browse/
   ├─ SmartViewListView.swift  # NEW: Browse — list of built-ins + live counts
   └─ FilteredTaskListView.swift # NEW: filtered flat list reusing TaskListRow
```

---

## Group A — Filtering engine (`GSDModel`, `swift test`, sub-second)

> Pure value-in/value-out with injected time. Build fully red→green before the store/UI. Run from the package root: `cd GSDKit && swift test --filter <SuiteName>`.

### Task A1: FilterCriteria + TaskFilter.apply (filtering, all criteria)

**Files:**
- Create: `GSDKit/Sources/GSDModel/FilterCriteria.swift`
- Create: `GSDKit/Sources/GSDModel/TaskFilter.swift`
- Test: `GSDKit/Tests/GSDModelTests/TaskFilterTests.swift`

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/TaskFilterTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct TaskFilterTests {
    /// Fixed UTC gregorian calendar; now = Mon 2026-06-15 09:00 UTC.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar(identifier: .gregorian).date(from: { var x = c; return x }())!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func task(_ id: String, urgent: Bool = false, important: Bool = false,
                      completed: Bool = false, completedAt: Date? = nil,
                      due: Date? = nil, recurrence: RecurrenceType = .none,
                      tags: [String] = [], deps: [String] = [], created: Date? = nil,
                      title: String = "", description: String = "",
                      subtasks: [Subtask] = []) -> Task {
        Task(id: id, title: title.isEmpty ? id : title, description: description,
             urgent: urgent, important: important, completed: completed, completedAt: completedAt,
             createdAt: created ?? Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0),
             dueDate: due, recurrence: recurrence, tags: tags, subtasks: subtasks, dependencies: deps)
    }
    private func ids(_ c: FilterCriteria, _ tasks: [Task]) -> Set<String> {
        Set(TaskFilter.apply(c, to: tasks, now: now, calendar: cal).map(\.id))
    }

    @Test func emptyCriteriaMatchesAll() {
        let ts = [task("a"), task("b", completed: true)]
        #expect(ids(FilterCriteria(), ts) == ["a", "b"])
    }
    @Test func statusActiveAndCompleted() {
        let ts = [task("a"), task("b", completed: true)]
        #expect(ids(FilterCriteria(status: .active), ts) == ["a"])
        #expect(ids(FilterCriteria(status: .completed), ts) == ["b"])
    }
    @Test func quadrantsMembership() {
        let ts = [task("q1", urgent: true, important: true), task("q4")]
        #expect(ids(FilterCriteria(quadrants: [.urgentImportant]), ts) == ["q1"])
    }
    @Test func tagsRequiresAll() {
        let ts = [task("a", tags: ["home", "errand"]), task("b", tags: ["home"])]
        #expect(ids(FilterCriteria(tags: ["home", "errand"]), ts) == ["a"])
    }
    @Test func recurrenceMembership() {
        let ts = [task("d", recurrence: .daily), task("n", recurrence: .none)]
        #expect(ids(FilterCriteria(recurrence: [.daily, .weekly, .monthly]), ts) == ["d"])
    }
    @Test func overdueRequiresActivePastDue() {
        let ts = [task("od", due: day(2026, 6, 14)), task("done", completed: true, due: day(2026, 6, 14)),
                  task("today", due: day(2026, 6, 15))]
        #expect(ids(FilterCriteria(overdue: true), ts) == ["od"])
    }
    @Test func dueTodayAndThisWeekHalfOpen() {
        let ts = [task("t", due: day(2026, 6, 15)), task("w6", due: day(2026, 6, 21)),
                  task("w7", due: day(2026, 6, 22))]
        #expect(ids(FilterCriteria(dueToday: true), ts) == ["t"])
        #expect(ids(FilterCriteria(dueThisWeek: true), ts) == ["t", "w6"]) // +7d excluded
    }
    @Test func noDueDate() {
        let ts = [task("none"), task("has", due: day(2026, 6, 20))]
        #expect(ids(FilterCriteria(noDueDate: true), ts) == ["none"])
    }
    @Test func dueDateRangeInclusive() {
        let ts = [task("in", due: day(2026, 6, 18)), task("out", due: day(2026, 7, 1))]
        let c = FilterCriteria(dueDateRange: .init(start: day(2026, 6, 1), end: day(2026, 6, 30)))
        #expect(ids(c, ts) == ["in"])
    }
    @Test func recentlyAddedAndCompleted() {
        let ts = [task("new", created: day(2026, 6, 12)), task("old", created: day(2026, 6, 1)),
                  task("won", completed: true, completedAt: day(2026, 6, 12)),
                  task("oldwin", completed: true, completedAt: day(2026, 6, 1))]
        #expect(ids(FilterCriteria(recentlyAdded: true), ts) == ["new"])
        #expect(ids(FilterCriteria(recentlyCompleted: true), ts) == ["won"])
    }
    @Test func readyToWorkUsesFullSet() {
        // a depends on b (incomplete) → blocked; c depends on d (complete) → ready.
        let ts = [task("a", deps: ["b"]), task("b"),
                  task("c", deps: ["d"]), task("d", completed: true)]
        // Even though status:.active would drop d from the result, d must still resolve as a completed blocker.
        #expect(ids(FilterCriteria(status: .active, readyToWork: true), ts) == ["b", "c"])
    }
    @Test func searchAcrossTitleDescriptionTagsAndSubtasks() {
        let ts = [task("t1", title: "Buy milk"),
                  task("t2", description: "call the MILKman"),
                  task("t3", tags: ["dairy-milk"]),
                  task("t4", subtasks: [Subtask(id: "s", title: "skim milk", completed: false)]),
                  task("t5", title: "unrelated")]
        #expect(ids(FilterCriteria(searchQuery: "milk"), ts) == ["t1", "t2", "t3", "t4"])
        #expect(ids(FilterCriteria(searchQuery: "  "), ts).count == 5) // whitespace = no constraint
    }
    @Test func criteriaAreANDed() {
        let ts = [task("a", urgent: true, important: true, tags: ["work"]),
                  task("b", urgent: true, important: true, tags: ["home"])]
        #expect(ids(FilterCriteria(quadrants: [.urgentImportant], tags: ["work"]), ts) == ["a"])
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskFilterTests` → FAIL (`FilterCriteria`/`TaskFilter` not found).

- [ ] **Step 3: Write `FilterCriteria.swift`:**
```swift
import Foundation

/// Predicate bundle powering smart views, filters, and search (product spec §5.9).
/// All present criteria are ANDed. A `Bool` flag of `false` means "don't constrain on
/// this" — only `true` adds a predicate. Empty arrays/`.all`/empty query = no constraint.
public struct FilterCriteria: Equatable, Sendable {
    public enum Status: Sendable, Equatable { case all, active, completed }
    public struct DateRange: Equatable, Sendable {
        public var start: Date?
        public var end: Date?
        public init(start: Date? = nil, end: Date? = nil) { self.start = start; self.end = end }
    }

    public var quadrants: [Quadrant]
    public var status: Status
    public var tags: [String]
    public var dueDateRange: DateRange?
    public var overdue: Bool
    public var dueToday: Bool
    public var dueThisWeek: Bool
    public var noDueDate: Bool
    public var recurrence: [RecurrenceType]
    public var recentlyAdded: Bool
    public var recentlyCompleted: Bool
    public var readyToWork: Bool
    public var searchQuery: String

    public init(quadrants: [Quadrant] = [], status: Status = .all, tags: [String] = [],
                dueDateRange: DateRange? = nil, overdue: Bool = false, dueToday: Bool = false,
                dueThisWeek: Bool = false, noDueDate: Bool = false, recurrence: [RecurrenceType] = [],
                recentlyAdded: Bool = false, recentlyCompleted: Bool = false, readyToWork: Bool = false,
                searchQuery: String = "") {
        self.quadrants = quadrants; self.status = status; self.tags = tags
        self.dueDateRange = dueDateRange; self.overdue = overdue; self.dueToday = dueToday
        self.dueThisWeek = dueThisWeek; self.noDueDate = noDueDate; self.recurrence = recurrence
        self.recentlyAdded = recentlyAdded; self.recentlyCompleted = recentlyCompleted
        self.readyToWork = readyToWork; self.searchQuery = searchQuery
    }
}
```

- [ ] **Step 4: Write `TaskFilter.swift`** (filtering only; sort added in A2). Date math is PROBE-VERIFIED:
```swift
import Foundation

/// Pure filtering over a task set (product spec §5.9). Caller injects `now`/`calendar`
/// so date predicates are deterministic. `readyToWork` resolves against the FULL input
/// set (a blocker excluded by another criterion must still block). PROBE-VERIFIED dates.
public enum TaskFilter {
    public static func apply(_ c: FilterCriteria, to tasks: [Task], now: Date, calendar: Calendar) -> [Task] {
        let startToday = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: startToday)!   // [startToday, +7)
        let recentCutoff = calendar.date(byAdding: .day, value: -7, to: now)!    // rolling from now
        let graph = DependencyGraph(tasks: tasks)
        let query = c.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return tasks.filter { task in
            switch c.status {
            case .all: break
            case .active: if task.completed { return false }
            case .completed: if !task.completed { return false }
            }
            if !c.quadrants.isEmpty, !c.quadrants.contains(task.quadrant) { return false }
            if !c.tags.allSatisfy({ task.tags.contains($0) }) { return false }
            if !c.recurrence.isEmpty, !c.recurrence.contains(task.recurrence) { return false }
            if let range = c.dueDateRange {
                guard let due = task.dueDate else { return false }
                if let s = range.start, due < s { return false }
                if let e = range.end, due > e { return false }
            }
            if c.overdue { guard !task.completed, let due = task.dueDate, due < startToday else { return false } }
            if c.dueToday { guard !task.completed, let due = task.dueDate, calendar.isDate(due, inSameDayAs: now) else { return false } }
            if c.dueThisWeek { guard !task.completed, let due = task.dueDate, due >= startToday, due < weekEnd else { return false } }
            if c.noDueDate, task.dueDate != nil { return false }
            if c.recentlyAdded { guard task.createdAt >= recentCutoff, task.createdAt <= now else { return false } }
            if c.recentlyCompleted { guard task.completed, let at = task.completedAt, at >= recentCutoff, at <= now else { return false } }
            if c.readyToWork { guard !task.completed, graph.uncompletedBlockers(of: task.id).isEmpty else { return false } }
            if !query.isEmpty {
                let hay = [task.title, task.description] + task.tags + task.subtasks.map(\.title)
                if !hay.contains(where: { $0.lowercased().contains(query) }) { return false }
            }
            return true
        }
    }
}
```

- [ ] **Step 5: Run** `cd GSDKit && swift test --filter TaskFilterTests` → PASS (13 tests).
- [ ] **Step 6: Commit:** `git add GSDKit/Sources/GSDModel/FilterCriteria.swift GSDKit/Sources/GSDModel/TaskFilter.swift GSDKit/Tests/GSDModelTests/TaskFilterTests.swift && git commit -m "feat: add FilterCriteria predicate bundle and pure TaskFilter pipeline"`

> **Probe note:** the date predicates (`overdue` < start-of-today; `dueToday` via `isDate(inSameDayAs:)`; `dueThisWeek` half-open `[startToday, startToday+7)`; `recentlyAdded`/`recentlyCompleted` rolling `[now−7d, now]`) were verified against the installed toolchain via a standalone probe (`/tmp/p3a-probe/probe.swift`, 16/16 assertions) before this plan shipped.

### Task A2: TaskFilter result sort

**Files:** Modify `GSDKit/Sources/GSDModel/TaskFilter.swift`; extend `TaskFilterTests.swift`.

- [ ] **Step 1: Add failing tests** to `TaskFilterTests.swift`:
```swift
    @Test func activeResultsSortByDueDateAscNilLast() {
        let ts = [task("late", due: day(2026, 6, 25)), task("none"),
                  task("soon", due: day(2026, 6, 16))]
        let r = TaskFilter.apply(FilterCriteria(status: .active), to: ts, now: now, calendar: cal)
        #expect(r.map(\.id) == ["soon", "late", "none"]) // due asc, nil last
    }
    @Test func completedResultsSortByCompletedAtDesc() {
        let ts = [task("old", completed: true, completedAt: day(2026, 6, 1)),
                  task("new", completed: true, completedAt: day(2026, 6, 14))]
        let r = TaskFilter.apply(FilterCriteria(status: .completed), to: ts, now: now, calendar: cal)
        #expect(r.map(\.id) == ["new", "old"])
    }
    @Test func dueDateTieBreaksByCreatedAtDesc() {
        let d = day(2026, 6, 20)
        let ts = [task("older", due: d, created: day(2026, 6, 1)),
                  task("newer", due: d, created: day(2026, 6, 10))]
        let r = TaskFilter.apply(FilterCriteria(status: .active), to: ts, now: now, calendar: cal)
        #expect(r.map(\.id) == ["newer", "older"])
    }
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskFilterTests` → FAIL (order assertions fail; filtering still returns input order).

- [ ] **Step 3: Add sorting to `apply`.** Replace the trailing `return tasks.filter { … }` so the filtered array is captured then sorted:
```swift
        let filtered = tasks.filter { task in
            // ... (unchanged predicate body) ...
            return true
        }
        if c.status == .completed {
            return filtered.sorted { a, b in
                switch (a.completedAt, b.completedAt) {
                case let (x?, y?): return x == y ? a.createdAt > b.createdAt : x > y
                case (_?, nil):    return true
                case (nil, _?):    return false
                case (nil, nil):   return a.createdAt > b.createdAt
                }
            }
        }
        return filtered.sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?): return x == y ? a.createdAt > b.createdAt : x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return a.createdAt > b.createdAt
            }
        }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskFilterTests` → PASS (16 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/TaskFilter.swift GSDKit/Tests/GSDModelTests/TaskFilterTests.swift && git commit -m "feat: sort filtered results (due asc / completedAt desc, createdAt tie-break)"`

### Task A3: SmartView + the 9 built-in smart views

**Files:**
- Create: `GSDKit/Sources/GSDModel/SmartView.swift`
- Test: `GSDKit/Tests/GSDModelTests/BuiltInSmartViewsTests.swift`

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/BuiltInSmartViewsTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct BuiltInSmartViewsTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return cal.date(from: c)!
    }
    private var now: Date { day(2026, 6, 15) }
    private func t(_ id: String, urgent: Bool = false, important: Bool = false,
                   completed: Bool = false, completedAt: Date? = nil, due: Date? = nil,
                   recurrence: RecurrenceType = .none, deps: [String] = [], created: Date? = nil) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             completedAt: completedAt, createdAt: created ?? Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0), dueDate: due, recurrence: recurrence, dependencies: deps)
    }
    private func view(_ id: String) -> SmartView { BuiltInSmartViews.all.first { $0.id == id }! }
    private func ids(_ id: String, _ tasks: [Task]) -> Set<String> {
        Set(TaskFilter.apply(view(id).criteria, to: tasks, now: now, calendar: cal).map(\.id))
    }

    @Test func thereAreNineStableBuiltIns() {
        #expect(BuiltInSmartViews.all.count == 9)
        #expect(BuiltInSmartViews.all.allSatisfy { $0.isBuiltIn })
        #expect(BuiltInSmartViews.all.map(\.id) ==
                ["today-focus", "this-week", "overdue", "no-deadline", "recently-added",
                 "weeks-wins", "all-completed", "recurring", "ready-to-work"])
    }
    @Test func todaysFocusIsActiveQ1() {
        let ts = [t("q1", urgent: true, important: true), t("q2", important: true),
                  t("done", urgent: true, important: true, completed: true)]
        #expect(ids("today-focus", ts) == ["q1"])
    }
    @Test func overdueBacklog() {
        let ts = [t("od", due: day(2026, 6, 14)), t("future", due: day(2026, 6, 20))]
        #expect(ids("overdue", ts) == ["od"])
    }
    @Test func recurringTasksView() {
        let ts = [t("w", recurrence: .weekly), t("none")]
        #expect(ids("recurring", ts) == ["w"])
    }
    @Test func readyToWorkView() {
        let ts = [t("blocked", deps: ["x"]), t("x"), t("free")]
        #expect(ids("ready-to-work", ts) == ["x", "free"])
    }
    @Test func weeksWinsIsRecentlyCompleted() {
        let ts = [t("won", completed: true, completedAt: day(2026, 6, 12)),
                  t("oldwin", completed: true, completedAt: day(2026, 6, 1))]
        #expect(ids("weeks-wins", ts) == ["won"])
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter BuiltInSmartViewsTests` → FAIL (`SmartView`/`BuiltInSmartViews` not found).

- [ ] **Step 3: Write `SmartView.swift`:**
```swift
import Foundation

/// A named, icon'd filter (product spec §5.6). In Phase 3a the 9 built-ins are in-code
/// constants (no `smartViews` table yet — custom views + persistence arrive in 3b).
public struct SmartView: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let icon: String          // SF Symbol name
    public let criteria: FilterCriteria
    public let isBuiltIn: Bool

    public init(id: String, name: String, icon: String, criteria: FilterCriteria, isBuiltIn: Bool = true) {
        self.id = id; self.name = name; self.icon = icon; self.criteria = criteria; self.isBuiltIn = isBuiltIn
    }
}

/// The nine read-only built-in views (product spec §6.13), stable IDs, canonical order.
public enum BuiltInSmartViews {
    public static let all: [SmartView] = [
        SmartView(id: "today-focus", name: String(localized: "Today's Focus"), icon: "target",
                  criteria: FilterCriteria(quadrants: [.urgentImportant], status: .active)),
        SmartView(id: "this-week", name: String(localized: "This Week"), icon: "calendar",
                  criteria: FilterCriteria(status: .active, dueThisWeek: true)),
        SmartView(id: "overdue", name: String(localized: "Overdue Backlog"), icon: "exclamationmark.triangle",
                  criteria: FilterCriteria(status: .active, overdue: true)),
        SmartView(id: "no-deadline", name: String(localized: "No Deadline"), icon: "calendar.badge.minus",
                  criteria: FilterCriteria(status: .active, noDueDate: true)),
        SmartView(id: "recently-added", name: String(localized: "Recently Added"), icon: "sparkles",
                  criteria: FilterCriteria(status: .active, recentlyAdded: true)),
        SmartView(id: "weeks-wins", name: String(localized: "This Week's Wins"), icon: "trophy",
                  criteria: FilterCriteria(status: .completed, recentlyCompleted: true)),
        SmartView(id: "all-completed", name: String(localized: "All Completed"), icon: "checkmark.circle",
                  criteria: FilterCriteria(status: .completed)),
        SmartView(id: "recurring", name: String(localized: "Recurring Tasks"), icon: "repeat",
                  criteria: FilterCriteria(status: .active, recurrence: [.daily, .weekly, .monthly])),
        SmartView(id: "ready-to-work", name: String(localized: "Ready to Work"), icon: "bolt",
                  criteria: FilterCriteria(status: .active, readyToWork: true)),
    ]
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter BuiltInSmartViewsTests` → PASS (6 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/SmartView.swift GSDKit/Tests/GSDModelTests/BuiltInSmartViewsTests.swift && git commit -m "feat: add SmartView type and the nine built-in smart views"`

> **Milestone after Group A:** the filtering engine + built-ins are green via `swift test`. Run `cd GSDKit && swift test --filter 'TaskFilterTests|BuiltInSmartViewsTests'` (22 tests) and the full `swift test` (no Phase 0–2 regression) before the store.

---

## Group B — Store query (`GSDStore`, `swift test`)

### Task B1: TaskStore.tasks(matching:)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreFilterTests.swift` (new)

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreFilterTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreFilterTests {
    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    /// now = 2026-06-15 09:00 UTC
    private let now = { () -> Date in
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 15; c.hour = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }()

    private func makeStore() throws -> (TaskStore, GRDBTaskRepository) {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory(), now: { Date(timeIntervalSince1970: 0) })
        let fixed = now
        let store = TaskStore(repository: repo, clock: { fixed }, calendar: utcCalendar())
        return (store, repo)
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.tasks.count < count && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }

    @Test func tasksMatchingFiltersByCriteria() async throws {
        let (store, repo) = try makeStore()
        try await repo.upsert(Task(id: "active", title: "A", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        try await repo.upsert(Task(id: "done", title: "B", urgent: true, important: true,
                                   completed: true, completedAt: now, createdAt: now, updatedAt: now))
        try await waitForTasks(store, count: 2)
        let active = store.tasks(matching: FilterCriteria(status: .active))
        #expect(active.map(\.id) == ["active"])
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreFilterTests` → FAIL (`tasks(matching:)` not found).

- [ ] **Step 3: Add to `TaskStore`** in `TaskStore.swift` (in a Queries section, near `tasks(in:showCompleted:)`):
```swift
    /// Tasks matching a `FilterCriteria` (product spec §5.9), resolved with the store's
    /// injected clock/calendar. Pure/derived — delegates to `TaskFilter`; never mutates.
    public func tasks(matching criteria: FilterCriteria) -> [Task] {
        TaskFilter.apply(criteria, to: tasks, now: clock(), calendar: calendar)
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreFilterTests` → PASS. Re-run `swift test` (full) → still green.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreFilterTests.swift && git commit -m "feat: add TaskStore.tasks(matching:) filtered query"`

> **Milestone after Group B:** `cd GSDKit && swift test` fully green (Phase 0–2's + Group A's + this). The pure + store layers are done; the rest is build-verified UI.

---

## Group C — Navigation shell + Browse UI (`xcodebuild`, iPhone + iPad)

> Build command (run after each task that says to build; run `xcodegen generate` first whenever a NEW file was added so the regenerated `GSD.xcodeproj` includes it):
> ```
> cd /Users/vinnycarpenter/Projects/gsd-iosapp
> xcodegen generate
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet ; echo "exit $?"
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build -quiet ; echo "exit $?"
> ```
> Exit 0 = success (the `-quiet` banner may be suppressed). If a simulator name is unavailable, run `xcrun simctl list devices available`, pick an equivalent iPhone / iPad-Pro device, and report which.
>
> **Read before C1:** `App/Matrix/QuadrantSection.swift` (the per-task row treatment you are extracting) and `App/Matrix/MatrixView.swift` (editor-sheet plumbing you mirror in C3). Do NOT rewrite Phase-1/2 behavior — extract and reuse it.

### Task C1: Extract `TaskListRow` and refactor `QuadrantSection` to use it

**Files:**
- Create: `App/Matrix/TaskListRow.swift`
- Modify: `App/Matrix/QuadrantSection.swift`

The per-task row treatment in `QuadrantSection` (TimelineView-wrapped `TaskCardView` + tap-to-edit + leading/trailing swipes + context menu + accessibility actions) is needed verbatim by the new `FilteredTaskListView`. Extract it into a reusable view so both share one definition. The iPad `QuadrantCell` (a grid, no swipes) is intentionally NOT touched.

- [ ] **Step 1:** Create `App/Matrix/TaskListRow.swift` — move the row body + `rowMenu` + `snoozeMenuPresets` out of `QuadrantSection` verbatim, parameterized by the per-task graph counts. The leading-swipe tint uses `QuadrantStyle.accent(task.quadrant)` (equal to the section's quadrant for matrix tasks, and correct per-task in a cross-quadrant filtered list):
```swift
import SwiftUI
import GSDModel
import GSDStore

/// One task as a `List` row — the shared treatment used by `QuadrantSection` (iPhone
/// matrix) and `FilteredTaskListView` (smart-view results). Live timer via `TimelineView`;
/// blocked/blocking counts injected by the container's `DependencyGraph`.
struct TaskListRow: View {
    let task: Task
    let blockedByCount: Int
    let blockingCount: Int
    let actions: TaskActions
    var onEdit: (Task) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            TaskCardView(task: task, now: context.date,
                         blockedByCount: blockedByCount, blockingCount: blockingCount)
        }
        .onTapGesture { onEdit(task) }
        .swipeActions(edge: .leading) {
            Button { actions.toggle(task) } label: {
                Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"),
                      systemImage: task.completed ? "arrow.uturn.left" : "checkmark")
            }
            .tint(QuadrantStyle.accent(task.quadrant))
        }
        .swipeActions(edge: .trailing) {
            Button(String(localized: "Snooze")) { actions.snooze(task, by: .oneHour) }.tint(.indigo)
            Button(role: .destructive) { actions.delete(task) } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .contextMenu { rowMenu }
        .accessibilityActions {
            Button(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete")) { actions.toggle(task) }
            Button(String(localized: "Edit")) { onEdit(task) }
            Button(String(localized: "Delete")) { actions.delete(task) }
            Button(String(localized: "Snooze 1 hour")) { actions.snooze(task, by: .oneHour) }
            if TimeTracking.runningEntry(task.timeEntries) == nil {
                Button(String(localized: "Start timer")) { actions.startTimer(task) }
            } else {
                Button(String(localized: "Stop timer")) { actions.stopTimer(task) }
            }
        }
    }

    @ViewBuilder private var rowMenu: some View {
        Button { onEdit(task) } label: { Label(String(localized: "Edit"), systemImage: "pencil") }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? String(localized: "Uncomplete") : String(localized: "Complete"), systemImage: "checkmark")
        }
        if TimeTracking.runningEntry(task.timeEntries) == nil {
            Button(String(localized: "Start Timer")) { actions.startTimer(task) }
        } else {
            Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
        }
        Menu(String(localized: "Snooze")) {
            ForEach(snoozeMenuPresets.indices, id: \.self) { i in
                Button(snoozeMenuPresets[i].0) { actions.snooze(task, by: snoozeMenuPresets[i].1) }
            }
        }
        Menu(String(localized: "Move to")) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(task, to: q) }
            }
        }
        Button(role: .destructive) { actions.delete(task) } label: { Label(String(localized: "Delete"), systemImage: "trash") }
    }

    /// Six §6.7 snooze presets — intentionally duplicated (not a shared constant), per the Phase-2 decision.
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes), (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour), (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow), (String(localized: "Next week"), .nextWeek)]
    }
}
```

- [ ] **Step 2:** In `QuadrantSection.swift`, replace the `ForEach(items) { task in … }` row body with a call to `TaskListRow`, and DELETE the now-moved `rowMenu(_:)` and `snoozeMenuPresets` members:
```swift
                ForEach(items) { task in
                    TaskListRow(
                        task: task,
                        blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                        blockingCount: graph.blockedTasks(of: task.id).count,
                        actions: actions,
                        onEdit: onEdit
                    )
                }
```
Leave the `Section`/header/empty-state (`onAdd`) and `graph`/`items`/`activeCount` exactly as they are.

- [ ] **Step 3: Build** (new file → `xcodegen generate` first) both simulators → exit 0. Launch the iPhone sim and confirm the matrix rows still complete/snooze/delete/edit via swipe + context menu (behavioral parity). 
- [ ] **Step 4: Commit:** `git add App/Matrix/TaskListRow.swift App/Matrix/QuadrantSection.swift GSD.xcodeproj && git commit -m "refactor: extract reusable TaskListRow from QuadrantSection"`

### Task C2: SmartViewListView (Browse) with live counts

**Files:** Create `App/Browse/SmartViewListView.swift`

- [ ] **Step 1:** Write the Browse list — the 9 built-ins with live counts, each pushing a `FilteredTaskListView` (created in C3; this file references it, so C2 and C3 build together — build at the end of C3):
```swift
import SwiftUI
import GSDModel
import GSDStore

/// Browse (iPhone tab): the built-in smart views with live counts; tap → filtered list.
struct SmartViewListView: View {
    var body: some View {
        NavigationStack {
            List(BuiltInSmartViews.all) { view in
                NavigationLink(value: view.id) { SmartViewRow(view: view) }
            }
            .navigationTitle(String(localized: "Browse"))
            .navigationDestination(for: String.self) { id in
                if let view = BuiltInSmartViews.all.first(where: { $0.id == id }) {
                    FilteredTaskListView(view: view)
                }
            }
        }
    }
}

/// A single smart-view row: icon + name + live result count. Reused by the iPad sidebar.
struct SmartViewRow: View {
    @Environment(TaskStore.self) private var store
    let view: SmartView
    private var count: Int { store.tasks(matching: view.criteria).count }

    var body: some View {
        Label {
            HStack {
                Text(view.name)
                Spacer()
                Text("\(count)").foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: view.icon)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(view.name), \(count) tasks"))
    }
}
```

- [ ] **Step 2:** (Build deferred to C3, which defines `FilteredTaskListView`.) Commit alongside C3.

### Task C3: FilteredTaskListView

**Files:** Create `App/Browse/FilteredTaskListView.swift`

The filtered flat list reuses `TaskListRow` (C1) and mirrors `MatrixView`'s editor-sheet + confetti plumbing (read `App/Matrix/MatrixView.swift`).

- [ ] **Step 1:** Write it:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// A smart view's results as a flat, cross-quadrant list. Reuses `TaskListRow`; owns its
/// own editor sheet + confetti (mirrors `MatrixView`). Read-only of `store.tasks(matching:)`.
struct FilteredTaskListView: View {
    @Environment(TaskStore.self) private var store
    let view: SmartView

    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0

    private var tasks: [Task] { store.tasks(matching: view.criteria) }
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    var body: some View {
        ZStack {
            Group {
                if tasks.isEmpty {
                    ContentUnavailableView(String(localized: "No tasks match"),
                                           systemImage: view.icon,
                                           description: Text(String(localized: "Tasks matching “\(view.name)” will appear here.")))
                } else {
                    List(tasks) { task in
                        TaskListRow(
                            task: task,
                            blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                            blockingCount: graph.blockedTasks(of: task.id).count,
                            actions: TaskActions(store: store) { confettiTrigger += 1 },
                            onEdit: { editor = .edit($0) }
                        )
                    }
                    .listStyle(.insetGrouped)
                }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .navigationTitle(view.name)
        .sheet(item: $editor) { TaskEditorView(request: $0) }
    }
}
```

- [ ] **Step 2: Build** (new files → `xcodegen generate` first) both simulators → exit 0.
- [ ] **Step 3: Commit:** `git add App/Browse GSD.xcodeproj && git commit -m "feat: add SmartViewListView (Browse) and FilteredTaskListView"`

### Task C4: Navigation shell — adaptive TabView / NavigationSplitView

**Files:** Modify `App/ContentView.swift`

Replace the bare size-class switch with the navigation shell: iPhone `TabView` (Matrix + Browse); iPad `NavigationSplitView` (sidebar: Matrix + a Smart Views section → detail shows the grid or a filtered list).

- [ ] **Step 1:** Rewrite `App/ContentView.swift`:
```swift
import SwiftUI
import GSDModel

/// Adaptive root. Compact (iPhone): a TabView (Matrix · Browse). Regular (iPad): a
/// NavigationSplitView (sidebar Matrix + Smart Views → detail grid / filtered list).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            TabView {
                MatrixView()
                    .tabItem { Label(String(localized: "Matrix"), systemImage: "square.grid.2x2") }
                SmartViewListView()
                    .tabItem { Label(String(localized: "Browse"), systemImage: "line.3.horizontal.decrease.circle") }
            }
        } else {
            RegularRootView()
        }
    }
}

/// iPad split view. Sidebar selection drives the detail column.
private struct RegularRootView: View {
    private enum Item: Hashable { case matrix, smartView(String) }
    @State private var selection: Item? = .matrix

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(String(localized: "Matrix"), systemImage: "square.grid.2x2").tag(Item.matrix)
                Section(String(localized: "Smart Views")) {
                    ForEach(BuiltInSmartViews.all) { view in
                        SmartViewRow(view: view).tag(Item.smartView(view.id))
                    }
                }
            }
            .navigationTitle("GSD")
        } detail: {
            switch selection {
            case .smartView(let id):
                if let view = BuiltInSmartViews.all.first(where: { $0.id == id }) {
                    NavigationStack { FilteredTaskListView(view: view) }
                } else {
                    MatrixGridView()
                }
            case .matrix, .none:
                MatrixGridView()
            }
        }
    }
}
```

- [ ] **Step 2: Build** both simulators → exit 0. Launch each: iPhone shows Matrix + Browse tabs; tapping Browse lists the 9 views with counts; tapping one shows the filtered list. iPad shows the sidebar (Matrix + Smart Views); selecting a view shows its filtered list in the detail column; selecting Matrix shows the grid. Capture a screenshot of each idiom.
- [ ] **Step 3: Commit:** `git add App/ContentView.swift GSD.xcodeproj && git commit -m "feat: add adaptive TabView/NavigationSplitView navigation shell with Browse"`

> **Milestone after Group C:** the 9 built-in smart views are usable on both idioms; filtered lists reuse the matrix row treatment; full `swift test` green; both simulators build. Behavioral/VoiceOver confirmation folds into the pending manual a11y pass.

---

## Phase 3a — Definition of Done

Mapped to the spec's acceptance criteria (A16–A19).

- [ ] **A16 — Filtering pipeline.** Every §5.9 field filters correctly, ANDed; date predicates correct under a pinned calendar/now (half-open week window, start-of-day overdue, rolling 7-day); `readyToWork` over the full set; `searchQuery` across title/description/tags/subtask-titles, case-insensitive; sort rule. *Tests:* `TaskFilterTests` (16).
- [ ] **A17 — Built-in views.** Each of the 9 yields the spec-correct set on a fixture; stable IDs; canonical order. *Tests:* `BuiltInSmartViewsTests` (6).
- [ ] **A18 — Store.** `tasks(matching:)` returns the filtered set using the store's clock/calendar. *Tests:* `TaskStoreFilterTests`.
- [ ] **A19 — Navigation/UI.** iPhone TabView (Matrix, Browse) + iPad NavigationSplitView sidebar build on both simulators; Browse lists views with live counts; selecting a view shows the filtered list reusing `TaskListRow`; empty state; VoiceOver labels on view rows. *Build:* both destinations exit 0.
- [ ] **Coverage.** `cd GSDKit && swift test` fully green, sub-second; both simulators build. One commit per task.

---

## Self-review (spec coverage · placeholders · type consistency)

**Spec coverage (§4–§10):** FilterCriteria all §5.9 fields (A1) ✔; pipeline incl. readyToWork-over-full-set + searchQuery + dates (A1, probe-verified) ✔; sort rule §5 (A2) ✔; 9 built-ins §4.3 (A3) ✔; store query §6 (B1) ✔; iPhone TabView + iPad sidebar §7.1–7.2 (C4) ✔; SmartViewListView live counts §7.3 (C2) ✔; FilteredTaskListView reusing the row + empty state §7.4 (C1, C3) ✔; deferred items untouched ✔.

**Placeholder scan:** every step has real Swift + exact commands. The one explicit "read the existing file then mirror" (C1/C3) references concrete files and provides the full new code; not a placeholder.

**Type consistency:** `FilterCriteria.Status`/`DateRange`, `TaskFilter.apply(_:to:now:calendar:)`, `SmartView`/`BuiltInSmartViews.all`, `TaskStore.tasks(matching:)`, `TaskListRow(task:blockedByCount:blockingCount:actions:onEdit:)`, `SmartViewRow(view:)`, `FilteredTaskListView(view:)` are used consistently across tasks. App refs match the real Phase-0/2 APIs (`TaskCardView(task:now:blockedByCount:blockingCount:)`, `TaskActions(store:onCompleted:)`, `EditorRequest.edit/.new`, `ConfettiView(trigger:)`, `QuadrantStyle.accent`, `Quadrant.allCases`, `TimeTracking.runningEntry`). `String(localized:)` in `GSDModel` is Foundation-provided (precedent: `TimeTracking.format`).
