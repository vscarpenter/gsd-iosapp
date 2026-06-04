# Phase 2 — Task Depth Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the full task-depth feature set on top of the Phase 1 matrix app — due dates + presets, the recurrence engine, subtasks, snooze, dependencies with BFS cycle prevention, and time tracking — as pure logic in `GSDModel` (TDD'd via `swift test`), store mutations in `TaskStore`, and editor/card extensions in the app. All offline; no notifications or sync (those are Phase 4/5).

**Architecture:** Correctness-critical logic lands as pure, dependency-free units in `GSDModel` (`RecurrenceEngine`, `DependencyGraph`, `TimeTracking`, `DueDatePresets`), each red→green→refactor'd with Swift Testing. Time-dependent logic takes an injected `Calendar` and/or `@Sendable () -> Date` clock so tests are deterministic. The `@MainActor @Observable TaskStore` (in `GSDStore`) grows mutation methods that compose those units and stamp `updatedAt` via its injected clock — `toggleComplete` additionally spawns a recurrence instance. `TaskEditorView` and `TaskCardView` (app target, build-verified via `xcodebuild`) grow new sections/indicators.

**Tech Stack:** Swift 6 (toolchain probed: Apple Swift 6.3.2), SwiftUI (Observation, `@Observable`), GSDKit (`GSDModel` zero-deps + `GSDStore` over GRDB from Phases 0–1), Swift Testing (`@Test`/`#expect`) for logic, `xcodebuild` for the app.

**Builds on (Phases 0–1, all committed on `main`):**
- `GSDModel`: `Task` (full init at `Task.swift`, incl. `dueDate`, `recurrence`, `subtasks`, `dependencies`, `parentTaskId`, `snoozedUntil`, `estimatedMinutes`, `timeSpent`, `timeEntries`, `notificationSent`/`lastNotificationAt`), `Subtask(id:title:completed:)`, `TimeEntry(id:startedAt:endedAt:notes:)`, `RecurrenceType` (`none`/`daily`/`weekly`/`monthly`), `Quadrant(urgent:important:)` + `.isUrgent`/`.isImportant`/`.title`, `IDGenerator.generate(size:)` + `IDGenerator.Size.{task,timeEntry}`, `FieldLimits` (incl. `maxSubtasks`, `maxDependencies`, `maxTimeEntries`, `estimatedMinutesRange`, `maxSnoozeInterval`, `normalizedEstimate`), `TaskValidator.validate(_:) throws`, `ValidationError`.
- `GSDStore`: `AppDatabase.live()`/`.inMemory()`, `TaskRepository` protocol (`upsert`/`fetchAll`/`fetch`/`delete`/`observeAll`; `delete` already scrubs the id from other tasks' `dependencies`), `GRDBTaskRepository(_:now:)`, and `TaskStore` (`@MainActor @Observable`; `start()`, `tasks`, `add`/`save`/`toggleComplete`/`move`/`delete`, `tasks(in:showCompleted:)`, injected `clock`/`newID`).
- App: `TaskEditorView(request:)` with `EditorRequest.{new,edit}`, `TaskCardView(task:)`, `QuadrantStyle.accent(_:)`/`.symbol(_:)`, `TaskActions`, `QuadrantSection`/`QuadrantCell`, `MatrixView`/`MatrixGridView`.

**Reference:** increment spec `docs/specs/2026-05-30-phase-0-2-foundations-core-depth.md` (§2.1 scope, §5 contracts, §9 edge cases, §10 acceptance A9–A13, §11 test stubs); product spec `spec.md` (§5.8 quadrants, §6.5 recurrence, §6.6 subtasks, §6.7 snooze, §6.8 dependencies/BFS, §6.9 time tracking, §6.10 due dates, Appendix A/B enums + limits).

---

## Architecture conventions locked by this plan (read first)

1. **`Task` naming (carried from Phase 1).** `GSDModel.Task` is the domain model. Use bare `Task` in type positions; for concurrency use SwiftUI's `.task { }` or, when an explicit spawn is unavoidable, the fully-qualified **`_Concurrency.Task { }`**. Never write bare `Task { }` in a file that imports `GSDModel`.
2. **`GSDModel` stays zero-dependency.** The four new pure units link only `Foundation` (for `Date`/`Calendar`). No GRDB, no SwiftUI. This is the structural bet that keeps the correctness loop sub-second (`swift test`).
3. **Inject time.** Every unit that reads "now" or does calendar math takes it as a parameter: `Calendar` for `RecurrenceEngine`/`DueDatePresets`, `now: Date` for spawn timestamps / snooze / time-entry stops. Pure functions, no `Date()` inside the unit. Tests pin a fixed `Calendar` (gregorian, explicit `timeZone`) and fixed dates.
4. **Weekday math is `firstWeekday`-INDEPENDENT (probe-verified).** Resolve "This week"/"Next week" with explicit `Calendar.component(.weekday, …)` arithmetic (Sun=1…Sat=7). **Do NOT** use `Calendar.dateInterval(of: .weekOfYear,…)` or read `Calendar.firstWeekday` — those are locale-dependent and silently break the presets under a Monday-first locale. A test pins both a Sunday-first and a Monday-first calendar and asserts identical results.
5. **Store is the only mutation path.** Views never touch the repository. Every `TaskStore` mutation stamps `updatedAt = clock()` (and `completedAt`/`snoozedUntil`/etc. as appropriate) so the §3.3 invariant holds at the use-case layer. The repository continues to own only its own cascade side-effects (the delete-scrub).
6. **Reminder fields exist but their UI is hidden (Phase 4).** `RecurrenceEngine` and snooze RESET reminder state (`notificationSent = false`, clear `lastNotificationAt`, clear `snoozedUntil` on spawn) per §6.5 — we set the fields, we just don't render reminder controls yet. No control that does nothing.
7. **Accessibility + localization (carried from Phase 1):** Dynamic Type, VoiceOver labels + custom actions, `String(localized:)` for all UI copy, ≥44pt hit targets.

---

## Scope calls made for Phase 2 (documented decisions; none block)

- **`timeSpent` rounding:** sum every completed entry's `(endedAt − startedAt)` in **seconds**, then floor the total to whole minutes (`Int(totalSeconds / 60)`). Chosen over floor-per-entry because it matches "sum … in whole minutes" most literally and avoids accumulating per-entry truncation error. Boundary tests pin `0→"< 1m"`, `59→"59m"`, `60→"1h"`, `61→"1h 1m"`. **Probe-verified.**
- **Recurrence single-level lineage:** spawned instance's `parentTaskId = task.parentTaskId ?? task.id`. Completing an instance-of-an-instance keeps pointing at the root, never chaining. **Probe-verified via the BFS/struct-copy logic; encoded explicitly + tested.**
- **Preset time-of-day:** Today/This week/Next week resolve to **start-of-day in the device's local time zone** (`Calendar.startOfDay`). Deterministic for the `DatePicker` default and overdue math. `None` → `nil`.
- **"Next week" from a weekend:** resolves to the immediately-upcoming Monday (e.g. Sun Jun 7 → Mon Jun 8), NOT a week later. Justified by the spec's own "This week on a weekend → next Friday" special-case, which only makes sense under a Monday-first week model where Sunday is the tail of the prior week. **Probe-verified across all 7 weekdays.**
- **Snooze does not auto-uncomplete or move tasks** — it only sets `snoozedUntil` (§6.7). Reminder rescheduling is Phase 4.
- **Time-entry note length (≤200) and snooze max (1 year)** are enforced at the action/UI layer (per `FieldLimits` comments), not inside `TaskValidator.validate`. The store clamps snooze to `maxSnoozeInterval`.
- **Deferred to later phases (out of Phase 2):** reminder UI/scheduling (§9, Phase 4); analytics "time-by-quadrant"/estimation-accuracy aggregates (§6.15, Phase 3); the "Ready to Work" smart *view* surface (§6.13, Phase 3) — but `DependencyGraph.readyTasks` is built now because the card de-emphasizes blocked tasks and Phase 3 will consume it.

---

## File Structure

```
GSDKit/Sources/GSDModel/
├─ RecurrenceEngine.swift        # advance dueDate + spawn next instance (Calendar injected)
├─ DependencyGraph.swift         # BFS cycle prevention + blocking/ready queries
├─ TimeTracking.swift            # start/stop entries, timeSpent recalculation, formatting
├─ DueDatePresets.swift          # None/Today/This week/Next week (Calendar injected)
└─ (Phase 0/1 files unchanged)

GSDKit/Tests/GSDModelTests/
├─ RecurrenceEngineTests.swift
├─ DependencyGraphTests.swift
├─ TimeTrackingTests.swift
└─ DueDatePresetsTests.swift

GSDKit/Sources/GSDStore/
└─ TaskStore.swift               # MODIFIED: recurrence on complete; snooze; timer; subtask + dependency mutations

GSDKit/Tests/GSDStoreTests/
└─ TaskStoreDepthTests.swift     # new file for the Phase-2 store behaviors

App/
├─ Editor/
│   └─ TaskEditorView.swift      # MODIFIED: due date + presets, recurrence, subtasks, dependencies, snooze, estimate, tracked readout
├─ Matrix/
│   └─ TaskCardView.swift        # MODIFIED: due date, recurrence glyph, subtask bar, dependency badges, live timer, snooze
└─ Support/
    └─ RelativeDate.swift        # small formatter helper for "Due today"/overdue/relative
```

`GSDModel` stays zero-dependency. `TaskStore` grows methods but keeps its existing signatures intact (so Phase 1 call sites compile unchanged). The editor and card are extended, not rewritten — Phase 1 fields stay.

---

## Group A — Pure-logic units (`GSDModel`, `swift test`, sub-second)

> The highest-value, most-probed group. Build these first, fully red→green, before touching the store or UI. All four are pure value-in/value-out with injected time. Run from the package root: `cd GSDKit && swift test --filter <SuiteName>`.

### Task A1: RecurrenceEngine — advance the due date

**Files:**
- Create: `GSDKit/Sources/GSDModel/RecurrenceEngine.swift`
- Test: `GSDKit/Tests/GSDModelTests/RecurrenceEngineTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/RecurrenceEngineTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct RecurrenceEngineTests {
    /// A fixed UTC gregorian calendar so date math is deterministic.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        return cal.date(from: comps)!
    }

    private func ymd(_ date: Date) -> (Int, Int, Int) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    @Test func dailyAdvancesOneDay() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 31), by: .daily, calendar: cal))
        #expect(ymd(next) == (2026, 2, 1))
    }

    @Test func weeklyAdvancesSevenDaysAcrossMonthBoundary() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 28), by: .weekly, calendar: cal))
        #expect(ymd(next) == (2026, 2, 4))
    }

    @Test func monthlyJan31ClampsToFebEndNonLeap() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2026, 2, 28))
    }

    @Test func monthlyJan31ClampsToFeb29InLeapYear() throws {
        let next = try #require(RecurrenceEngine.advance(date(2024, 1, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2024, 2, 29))
    }

    @Test func monthlyMar31ClampsToApr30() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 3, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2026, 4, 30))
    }

    @Test func noneReturnsNil() {
        #expect(RecurrenceEngine.advance(date(2026, 1, 31), by: .none, calendar: cal) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter RecurrenceEngineTests`
Expected: FAIL — `cannot find 'RecurrenceEngine' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/RecurrenceEngine.swift`:
```swift
import Foundation

/// Recurrence date math + instance spawning (product spec §6.5). Pure: the
/// caller injects the `Calendar` (so month-end clamping and time zone are
/// deterministic) and "now" (so spawn timestamps are testable).
public enum RecurrenceEngine {
    /// Advance a due date by one recurrence period. `.none` (no recurrence) and a
    /// `.daily`/`.weekly`/`.monthly` with no due date both return nil — there is
    /// nothing to advance. Monthly uses `Calendar` month arithmetic, which clamps
    /// to the last valid day (Jan 31 + 1mo → Feb 28/29). PROBE-VERIFIED.
    public static func advance(_ dueDate: Date?, by recurrence: RecurrenceType, calendar: Calendar) -> Date? {
        guard let dueDate else { return nil }
        switch recurrence {
        case .none:    return nil
        case .daily:   return calendar.date(byAdding: .day, value: 1, to: dueDate)
        case .weekly:  return calendar.date(byAdding: .day, value: 7, to: dueDate)
        case .monthly: return calendar.date(byAdding: .month, value: 1, to: dueDate)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter RecurrenceEngineTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/RecurrenceEngine.swift GSDKit/Tests/GSDModelTests/RecurrenceEngineTests.swift
git commit -m "feat: add recurrence due-date advancement with month-end clamping"
```

> Month-end clamping (Jan 31 + 1mo → Feb 28 non-leap / Feb 29 leap; Mar 31 → Apr 30) was empirically verified against the installed toolchain via a standalone probe before this plan shipped.

### Task A2: RecurrenceEngine — spawn the next instance

**Files:**
- Modify: `GSDKit/Sources/GSDModel/RecurrenceEngine.swift`
- Test: extend `GSDKit/Tests/GSDModelTests/RecurrenceEngineTests.swift`

- [ ] **Step 1: Add failing tests** to `RecurrenceEngineTests.swift`:
```swift
    private func recurringTask() -> Task {
        let created = date(2026, 1, 1)
        return Task(
            id: "orig", title: "Water plants", description: "weekly",
            urgent: false, important: true,
            completed: true, completedAt: date(2026, 1, 31),
            createdAt: created, updatedAt: date(2026, 1, 31),
            dueDate: date(2026, 1, 31), recurrence: .monthly,
            tags: ["home"],
            subtasks: [Subtask(id: "s1", title: "fill can", completed: true),
                       Subtask(id: "s2", title: "mist leaves", completed: true)],
            dependencies: ["dep1"],
            notificationSent: true,
            lastNotificationAt: date(2026, 1, 30),
            snoozedUntil: date(2026, 2, 1),
            estimatedMinutes: 10,
            timeSpent: 12,
            timeEntries: [TimeEntry(id: "te000001", startedAt: date(2026, 1, 31))]
        )
    }

    @Test func spawnAdvancesDueDateAndAssignsNewIdentity() throws {
        let now = date(2026, 1, 31)
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: now,
                                                           newID: "newid", calendar: cal))
        #expect(next.id == "newid")
        #expect(ymd(try #require(next.dueDate)) == (2026, 2, 28)) // monthly clamp
        #expect(next.createdAt == now && next.updatedAt == now)
        #expect(next.completed == false && next.completedAt == nil)
    }

    @Test func spawnResetsSubtasksToIncompleteKeepingTitlesAndOrder() throws {
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.subtasks.map(\.title) == ["fill can", "mist leaves"])
        #expect(next.subtasks.allSatisfy { !$0.completed })
        // Subtask ids are regenerated so the spawned checklist is independent.
        #expect(next.subtasks.map(\.id) != ["s1", "s2"])
    }

    @Test func spawnResetsReminderAndTimeTrackingAndKeepsRecurrenceAndTagsAndDeps() throws {
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.recurrence == .monthly)
        #expect(next.tags == ["home"])
        #expect(next.dependencies == ["dep1"])
        #expect(next.notificationSent == false)
        #expect(next.lastNotificationAt == nil)
        #expect(next.snoozedUntil == nil)
        #expect(next.timeSpent == nil)
        #expect(next.timeEntries.isEmpty)
    }

    @Test func spawnUsesRootIdForSingleLevelLineage() throws {
        // Original was itself a spawned instance (parentTaskId set). The new
        // instance must point at the ROOT, not chain off the instance.
        var instance = recurringTask()
        instance.id = "instance-2"
        instance.parentTaskId = "root-id"
        let next = try #require(RecurrenceEngine.spawnNext(from: instance, now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.parentTaskId == "root-id")
    }

    @Test func spawnFromRootSetsParentToRootId() throws {
        // Original has no parent → it IS the root → child points at it.
        let next = try #require(RecurrenceEngine.spawnNext(from: recurringTask(), now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.parentTaskId == "orig")
    }

    @Test func spawnWithNoDueDateStaysNoDueDate() throws {
        var t = recurringTask()
        t.dueDate = nil
        let next = try #require(RecurrenceEngine.spawnNext(from: t, now: date(2026, 1, 31),
                                                           newID: "newid", calendar: cal))
        #expect(next.dueDate == nil)
    }

    @Test func spawnReturnsNilForNonRecurringTask() {
        var t = recurringTask()
        t.recurrence = .none
        #expect(RecurrenceEngine.spawnNext(from: t, now: date(2026, 1, 31),
                                           newID: "newid", calendar: cal) == nil)
    }
}
```

> The two trailing `}` above close `spawnWithNoDueDate…` / `spawnReturnsNil…` and the `struct`. The `subtaskID` closure parameter (Step 3) lets the test inject deterministic ids without coupling to `IDGenerator`'s randomness — the default uses `IDGenerator`. The test asserts only that the ids CHANGED, so no `subtaskID:` argument is passed.

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter RecurrenceEngineTests` → FAIL (`spawnNext` not found).

- [ ] **Step 3: Add to `RecurrenceEngine`** in `RecurrenceEngine.swift`:
```swift
extension RecurrenceEngine {
    /// Spawn the next instance of a recurring task on completion (product spec §6.5).
    /// Returns nil when the task does not recur. The original (completed) task is the
    /// caller's to keep as a historical record; this returns only the NEW instance.
    ///
    /// Single-level lineage: the new instance's `parentTaskId` is the original's
    /// `parentTaskId ?? id` — completing an instance-of-an-instance still points at
    /// the root, never chaining (product spec §9, increment spec §9).
    ///
    /// `subtaskID` regenerates subtask ids so the spawned checklist is independent
    /// of the historical one; injected for test determinism.
    public static func spawnNext(
        from task: Task,
        now: Date,
        newID: String,
        calendar: Calendar,
        subtaskID: () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) }
    ) -> Task? {
        guard task.recurrence != .none else { return nil }
        return Task(
            id: newID,
            title: task.title,
            description: task.description,
            urgent: task.urgent,
            important: task.important,
            completed: false,
            completedAt: nil,
            createdAt: now,
            updatedAt: now,
            dueDate: advance(task.dueDate, by: task.recurrence, calendar: calendar),
            recurrence: task.recurrence,
            tags: task.tags,
            subtasks: task.subtasks.map { Subtask(id: subtaskID(), title: $0.title, completed: false) },
            dependencies: task.dependencies,
            parentTaskId: task.parentTaskId ?? task.id,
            notifyBefore: task.notifyBefore,
            notificationEnabled: task.notificationEnabled,
            notificationSent: false,
            lastNotificationAt: nil,
            snoozedUntil: nil,
            estimatedMinutes: task.estimatedMinutes,
            timeSpent: nil,
            timeEntries: []
        )
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter RecurrenceEngineTests` → PASS (13 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/RecurrenceEngine.swift GSDKit/Tests/GSDModelTests/RecurrenceEngineTests.swift && git commit -m "feat: spawn recurrence instances with reset state and single-level lineage"`


### Task A3: DependencyGraph — BFS cycle prevention + queries

**Files:**
- Create: `GSDKit/Sources/GSDModel/DependencyGraph.swift`
- Test: `GSDKit/Tests/GSDModelTests/DependencyGraphTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/DependencyGraphTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct DependencyGraphTests {
    private func task(_ id: String, deps: [String] = [], completed: Bool = false) -> Task {
        let now = Date(timeIntervalSince1970: 0)
        return Task(id: id, title: id, urgent: true, important: true,
                    completed: completed, createdAt: now, updatedAt: now, dependencies: deps)
    }

    /// Chain: A ──depends on──▶ B ──depends on──▶ C   (edges point to prerequisites)
    private func chain() -> DependencyGraph {
        DependencyGraph(tasks: [task("A", deps: ["B"]), task("B", deps: ["C"]), task("C")])
    }

    @Test func selfReferenceRejected() {
        #expect(chain().wouldCreateCycle(adding: "A", to: "A"))
    }

    @Test func edgeClosingCycleRejectedViaBfs() {
        // Adding A as a dependency of C closes C→A→B→C.
        #expect(chain().wouldCreateCycle(adding: "A", to: "C"))
    }

    @Test func transitiveButAcyclicEdgeAllowed() {
        // Adding C as a direct dependency of A is redundant but creates no cycle.
        #expect(!chain().wouldCreateCycle(adding: "C", to: "A"))
    }

    @Test func existingEdgeReAddedIsNotACycle() {
        #expect(!chain().wouldCreateCycle(adding: "B", to: "A"))
    }

    @Test func validateAddRejectsMissingId() {
        #expect(throws: DependencyError.missingTask) {
            try chain().validateAdd(dependency: "ZZZ", to: "A")
        }
    }

    @Test func validateAddRejectsSelfReference() {
        #expect(throws: DependencyError.selfReference) {
            try chain().validateAdd(dependency: "A", to: "A")
        }
    }

    @Test func validateAddRejectsCycle() {
        #expect(throws: DependencyError.cycle) {
            try chain().validateAdd(dependency: "A", to: "C")
        }
    }

    @Test func validateAddAcceptsValidEdge() throws {
        try chain().validateAdd(dependency: "C", to: "A") // redundant but legal
    }

    @Test func blockingTasksAreTheDirectDependencies() {
        #expect(chain().blockingTasks(of: "A").map(\.id) == ["B"])
    }

    @Test func uncompletedBlockersExcludeCompletedPrerequisites() {
        let g = DependencyGraph(tasks: [task("A", deps: ["B", "C"]),
                                        task("B", completed: true),
                                        task("C", completed: false)])
        #expect(g.uncompletedBlockers(of: "A").map(\.id) == ["C"])
        #expect(g.isBlocked("A"))
    }

    @Test func notBlockedWhenAllPrerequisitesComplete() {
        let g = DependencyGraph(tasks: [task("A", deps: ["B"]), task("B", completed: true)])
        #expect(!g.isBlocked("A"))
        #expect(g.uncompletedBlockers(of: "A").isEmpty)
    }

    @Test func blockedTasksAreTasksDependingOnThisOne() {
        // C blocks B (B depends on C). So blockedTasks(of: C) includes B.
        #expect(chain().blockedTasks(of: "C").map(\.id) == ["B"])
    }

    @Test func readyTasksExcludeIncompleteBlockersAndCompletedTasks() {
        // Chain A→B→C all incomplete: only C is ready (no uncompleted blockers).
        #expect(chain().readyTasks().map(\.id) == ["C"])
    }

    @Test func readyTasksExcludeAlreadyCompletedTasks() {
        let g = DependencyGraph(tasks: [task("A", completed: true), task("B")])
        #expect(g.readyTasks().map(\.id) == ["B"])
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter DependencyGraphTests` → FAIL (`DependencyGraph` not found).

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/DependencyGraph.swift`:
```swift
import Foundation

public enum DependencyError: Error, Equatable {
    case selfReference
    case missingTask
    case cycle
}

/// The blocking graph over a task set (product spec §6.8). Edges point from a task
/// to its prerequisites (`task.dependencies`). Pure value type — built from a
/// snapshot, queried, discarded. BFS cycle detection is PROBE-VERIFIED.
public struct DependencyGraph {
    private let byID: [String: Task]
    /// Stable iteration order for deterministic query results.
    private let order: [String]

    public init(tasks: [Task]) {
        var map: [String: Task] = [:]
        var ids: [String] = []
        for task in tasks where map[task.id] == nil {
            map[task.id] = task
            ids.append(task.id)
        }
        self.byID = map
        self.order = ids
    }

    // MARK: Cycle prevention

    /// True if adding `dependency` as a prerequisite of `taskID` would create a cycle.
    /// Self-reference always counts. BFS walks FROM `dependency` over existing edges;
    /// if `taskID` is reachable, the new edge closes a loop.
    public func wouldCreateCycle(adding dependency: String, to taskID: String) -> Bool {
        if dependency == taskID { return true }
        var queue = [dependency]
        var visited: Set<String> = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            if current == taskID { return true }
            if !visited.insert(current).inserted { continue }
            if let task = byID[current] { queue.append(contentsOf: task.dependencies) }
        }
        return false
    }

    /// Validate an edge before it is added (product spec §6.8): no self-reference,
    /// the dependency must exist, and it must not close a cycle.
    public func validateAdd(dependency: String, to taskID: String) throws {
        guard dependency != taskID else { throw DependencyError.selfReference }
        guard byID[dependency] != nil else { throw DependencyError.missingTask }
        guard !wouldCreateCycle(adding: dependency, to: taskID) else { throw DependencyError.cycle }
    }

    // MARK: Queries

    /// A task's direct prerequisites (its `dependencies`), resolved to tasks.
    public func blockingTasks(of taskID: String) -> [Task] {
        (byID[taskID]?.dependencies ?? []).compactMap { byID[$0] }
    }

    /// Prerequisites that are not yet complete.
    public func uncompletedBlockers(of taskID: String) -> [Task] {
        blockingTasks(of: taskID).filter { !$0.completed }
    }

    /// True if any prerequisite is incomplete.
    public func isBlocked(_ taskID: String) -> Bool {
        !uncompletedBlockers(of: taskID).isEmpty
    }

    /// Tasks that list `taskID` among their dependencies (i.e. this task blocks them).
    public func blockedTasks(of taskID: String) -> [Task] {
        order.compactMap { byID[$0] }.filter { $0.dependencies.contains(taskID) }
    }

    /// Incomplete tasks with no uncompleted blockers — the "Ready to Work" set.
    public func readyTasks() -> [Task] {
        order.compactMap { byID[$0] }.filter { !$0.completed && !isBlocked($0.id) }
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter DependencyGraphTests` → PASS (14 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/DependencyGraph.swift GSDKit/Tests/GSDModelTests/DependencyGraphTests.swift && git commit -m "feat: add dependency graph with BFS cycle prevention and queries"`

> The BFS cycle-detection logic (cycle-closing edge → reject; transitive-but-acyclic → allow; self-reference → reject) and `readyTasks` exclusion of incomplete-blocker chains were verified against the installed toolchain via a standalone probe before this plan shipped.

### Task A4: TimeTracking — start/stop entries, timeSpent, formatting

**Files:**
- Create: `GSDKit/Sources/GSDModel/TimeTracking.swift`
- Test: `GSDKit/Tests/GSDModelTests/TimeTrackingTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/TimeTrackingTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct TimeTrackingTests {
    private let epoch = Date(timeIntervalSince1970: 0)
    private func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

    private func entry(_ id: String, start: TimeInterval, end: TimeInterval?) -> TimeEntry {
        TimeEntry(id: id, startedAt: at(start), endedAt: end.map(at))
    }

    @Test func startAddsRunningEntry() throws {
        var entries: [TimeEntry] = []
        entries = try TimeTracking.start(entries, now: at(0), newID: "te000001")
        #expect(entries.count == 1)
        #expect(entries[0].endedAt == nil)
        #expect(entries[0].startedAt == at(0))
    }

    @Test func startWhileRunningIsRejected() {
        let running = [entry("te000001", start: 0, end: nil)]
        #expect(throws: TimeTrackingError.alreadyRunning) {
            _ = try TimeTracking.start(running, now: at(10), newID: "te000002")
        }
    }

    @Test func stopClosesRunningEntry() throws {
        let running = [entry("te000001", start: 0, end: nil)]
        let stopped = try TimeTracking.stop(running, now: at(90))
        #expect(stopped[0].endedAt == at(90))
    }

    @Test func stopWithNoRunningEntryIsRejected() {
        let closed = [entry("te000001", start: 0, end: 60)]
        #expect(throws: TimeTrackingError.notRunning) {
            _ = try TimeTracking.stop(closed, now: at(90))
        }
    }

    @Test func runningEntryExposesTheOpenEntry() {
        let entries = [entry("a", start: 0, end: 60), entry("b", start: 70, end: nil)]
        #expect(TimeTracking.runningEntry(entries)?.id == "b")
    }

    @Test func timeSpentSumsCompletedEntriesInWholeMinutes() {
        // 90s + 150s = 240s = 4 min. A running entry contributes nothing.
        let entries = [entry("a", start: 0, end: 90),
                       entry("b", start: 100, end: 250),
                       entry("c", start: 300, end: nil)]
        #expect(TimeTracking.timeSpentMinutes(entries) == 4)
    }

    @Test func timeSpentFloorsPartialMinutes() {
        // 59s → 0; sum-then-floor (PROBE-VERIFIED scope call).
        #expect(TimeTracking.timeSpentMinutes([entry("a", start: 0, end: 59)]) == 0)
        #expect(TimeTracking.timeSpentMinutes([entry("a", start: 0, end: 119)]) == 1)
    }

    @Test func formatBoundaries() {
        #expect(TimeTracking.format(minutes: 0) == "< 1m")
        #expect(TimeTracking.format(minutes: 1) == "1m")
        #expect(TimeTracking.format(minutes: 59) == "59m")
        #expect(TimeTracking.format(minutes: 60) == "1h")
        #expect(TimeTracking.format(minutes: 61) == "1h 1m")
        #expect(TimeTracking.format(minutes: 120) == "2h")
        #expect(TimeTracking.format(minutes: 125) == "2h 5m")
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TimeTrackingTests` → FAIL (`TimeTracking` not found).

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/TimeTracking.swift`:
```swift
import Foundation

public enum TimeTrackingError: Error, Equatable {
    case alreadyRunning
    case notRunning
}

/// Pure time-tracking operations over a task's `timeEntries` (product spec §6.9).
/// At most one running entry; `timeSpent` sums COMPLETED entries' seconds and
/// floors to whole minutes (sum-then-floor — documented scope call, PROBE-VERIFIED).
public enum TimeTracking {
    /// The single open (running) entry, if any.
    public static func runningEntry(_ entries: [TimeEntry]) -> TimeEntry? {
        entries.first { $0.endedAt == nil }
    }

    /// Begin a new entry. Rejects a second concurrent start.
    public static func start(_ entries: [TimeEntry], now: Date, newID: String) throws -> [TimeEntry] {
        guard runningEntry(entries) == nil else { throw TimeTrackingError.alreadyRunning }
        var result = entries
        result.append(TimeEntry(id: newID, startedAt: now))
        return result
    }

    /// Close the running entry. Optional notes attach to it. Rejects when none runs.
    public static func stop(_ entries: [TimeEntry], now: Date, notes: String? = nil) throws -> [TimeEntry] {
        guard let index = entries.firstIndex(where: { $0.endedAt == nil }) else {
            throw TimeTrackingError.notRunning
        }
        var result = entries
        result[index].endedAt = now
        if let notes { result[index].notes = notes }
        return result
    }

    /// Sum completed entries' durations in seconds, then floor to whole minutes.
    public static func timeSpentMinutes(_ entries: [TimeEntry]) -> Int {
        let totalSeconds = entries.reduce(0.0) { sum, entry in
            guard let endedAt = entry.endedAt else { return sum }
            return sum + endedAt.timeIntervalSince(entry.startedAt)
        }
        return Int(totalSeconds / 60.0)
    }

    /// Human-readable duration (product spec §6.9): `< 1m` / `Xm` / `Xh` / `Xh Ym`.
    public static func format(minutes: Int) -> String {
        if minutes < 1 { return String(localized: "< 1m") }
        if minutes < 60 { return String(localized: "\(minutes)m") }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(localized: "\(hours)h")
            : String(localized: "\(hours)h \(remainder)m")
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TimeTrackingTests` → PASS (8 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/TimeTracking.swift GSDKit/Tests/GSDModelTests/TimeTrackingTests.swift && git commit -m "feat: add time-tracking entries, timeSpent recalculation, and formatting"`

> The `timeSpent` sum-then-floor rounding and the format boundaries (0→"< 1m", 59→"59m", 60→"1h", 61→"1h 1m") were verified against the installed toolchain via a standalone probe before this plan shipped.


### Task A5: DueDatePresets — None / Today / This week / Next week

**Files:**
- Create: `GSDKit/Sources/GSDModel/DueDatePresets.swift`
- Test: `GSDKit/Tests/GSDModelTests/DueDatePresetsTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/DueDatePresetsTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct DueDatePresetsTests {
    /// June 2026: 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat, 7=Sun.
    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.firstWeekday = firstWeekday
        return c
    }
    private func day(_ d: Int, cal: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = d; comps.hour = 9
        return cal.date(from: comps)!
    }
    private func ymd(_ date: Date, cal: Calendar) -> (Int, Int, Int) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    @Test func noneIsNil() {
        let cal = calendar(firstWeekday: 1)
        #expect(DueDatePresets.resolve(.none, today: day(3, cal: cal), calendar: cal) == nil)
    }

    @Test func todayIsStartOfToday() {
        let cal = calendar(firstWeekday: 1)
        let resolved = DueDatePresets.resolve(.today, today: day(3, cal: cal), calendar: cal)!
        #expect(ymd(resolved, cal: cal) == (2026, 6, 3))
        #expect(resolved == cal.startOfDay(for: day(3, cal: cal)))
    }

    @Test func thisWeekResolvesToFridayOnWeekdays() {
        let cal = calendar(firstWeekday: 1)
        for d in 1...5 { // Mon..Fri
            let resolved = DueDatePresets.resolve(.thisWeek, today: day(d, cal: cal), calendar: cal)!
            #expect(ymd(resolved, cal: cal) == (2026, 6, 5)) // Fri Jun 5
        }
    }

    @Test func thisWeekOnWeekendResolvesToNextFriday() {
        let cal = calendar(firstWeekday: 1)
        for d in [6, 7] { // Sat, Sun
            let resolved = DueDatePresets.resolve(.thisWeek, today: day(d, cal: cal), calendar: cal)!
            #expect(ymd(resolved, cal: cal) == (2026, 6, 12)) // next Fri
        }
    }

    @Test func nextWeekResolvesToMondayStrictlyAfterToday() {
        let cal = calendar(firstWeekday: 1)
        // Mon..Sun all resolve to Mon Jun 8 (Mon→+7; Sun→+1, the upcoming Monday).
        for d in 1...7 {
            let resolved = DueDatePresets.resolve(.nextWeek, today: day(d, cal: cal), calendar: cal)!
            #expect(ymd(resolved, cal: cal) == (2026, 6, 8))
        }
    }

    @Test func presetsAreIndependentOfFirstWeekday() {
        // PROBE-VERIFIED: explicit weekday arithmetic must not depend on locale.
        let sun = calendar(firstWeekday: 1)
        let mon = calendar(firstWeekday: 2)
        for d in 1...7 {
            for preset in [DueDatePreset.thisWeek, .nextWeek] {
                let a = DueDatePresets.resolve(preset, today: day(d, cal: sun), calendar: sun)
                let b = DueDatePresets.resolve(preset, today: day(d, cal: mon), calendar: mon)
                #expect(a == b)
            }
        }
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter DueDatePresetsTests` → FAIL (`DueDatePresets` not found).

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/DueDatePresets.swift`:
```swift
import Foundation

/// The four quick-set due-date presets (product spec §6.10).
public enum DueDatePreset: String, CaseIterable, Sendable {
    case none, today, thisWeek, nextWeek

    public var label: String {
        switch self {
        case .none:     String(localized: "None")
        case .today:    String(localized: "Today")
        case .thisWeek: String(localized: "This week")
        case .nextWeek: String(localized: "Next week")
        }
    }
}

/// Resolves a preset to a concrete due date (product spec §6.10), all in the
/// injected calendar's time zone, at START OF DAY. Weekday math uses explicit
/// `.weekday` component arithmetic (Sun=1…Sat=7) so it is INDEPENDENT of the
/// calendar's `firstWeekday`/locale. PROBE-VERIFIED — do NOT refactor to
/// `dateInterval(of: .weekOfYear,…)`, which IS locale-dependent.
public enum DueDatePresets {
    private static let friday = 6   // gregorian weekday number
    private static let monday = 2

    public static func resolve(_ preset: DueDatePreset, today: Date, calendar: Calendar) -> Date? {
        let start = calendar.startOfDay(for: today)
        switch preset {
        case .none:
            return nil
        case .today:
            return start
        case .thisWeek:
            return thisWeekFriday(from: start, calendar: calendar)
        case .nextWeek:
            return nextWeekMonday(from: start, calendar: calendar)
        }
    }

    /// Friday of the current week; if today is Sat/Sun, the NEXT Friday.
    private static func thisWeekFriday(from start: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: start) // 1=Sun…7=Sat
        let delta: Int
        if weekday == 7 || weekday == 1 { // Saturday or Sunday → next Friday
            let raw = (friday - weekday + 7) % 7
            delta = raw == 0 ? 7 : raw
        } else { // Mon…Fri → this week's Friday (today if already Friday)
            delta = friday - weekday
        }
        return calendar.date(byAdding: .day, value: delta, to: start)!
    }

    /// Monday of next week, strictly after today (today-is-Monday → +7).
    private static func nextWeekMonday(from start: Date, calendar: Calendar) -> Date {
        let weekday = calendar.component(.weekday, from: start)
        var delta = (monday - weekday + 7) % 7
        if delta == 0 { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: start)!
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter DueDatePresetsTests` → PASS (6 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/DueDatePresets.swift GSDKit/Tests/GSDModelTests/DueDatePresetsTests.swift && git commit -m "feat: add due-date presets with firstWeekday-independent weekday math"`

> The preset weekday math (This week → Friday / next Friday on a weekend; Next week → Monday strictly after today) AND its independence from the calendar's `firstWeekday` were verified against the installed toolchain via a standalone probe (Sunday-first and Monday-first calendars agree on all 7 weekdays) before this plan shipped.

> **Milestone after Group A:** all four correctness-critical pure units are green via `swift test` (sub-second, no simulator). Run `cd GSDKit && swift test --filter 'RecurrenceEngineTests|DependencyGraphTests|TimeTrackingTests|DueDatePresetsTests'` once to confirm the suite is clean before moving to the store.

---

## Group B — Store extensions (`TaskStore`, `swift test`)

> `TaskStore` lives in `GSDStore` so these are testable via `swift test` against an in-memory `GRDBTaskRepository`. Every method stamps `updatedAt = clock()`. `toggleComplete` is MODIFIED to spawn a recurrence instance; the rest are new. Phase 1 signatures are untouched.
>
> **Calendar injection.** `TaskStore` gains an injected `calendar` (default `Calendar.current`) used only by recurrence/preset composition. Add it to the initializer alongside `clock`/`newID`. Existing call sites (which omit it) keep compiling via the default.

### Task B1: TaskStore gains an injected calendar (prep)

**Files:** Modify `GSDKit/Sources/GSDStore/TaskStore.swift`

- [ ] **Step 1:** Add a stored `calendar` and an initializer parameter (defaulted, so Phase 1 call sites are unaffected). In `TaskStore`:
```swift
    private let calendar: Calendar
```
and extend `init` (add the parameter LAST, defaulted):
```swift
    public init(
        repository: any TaskRepository,
        clock: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) },
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.clock = clock
        self.newID = newID
        self.calendar = calendar
    }
```
- [ ] **Step 2:** Build the package to confirm nothing broke: `cd GSDKit && swift build` → succeeds. (No behavior change yet; existing tests still pass: `swift test --filter TaskStoreTests`.)
- [ ] **Step 3:** Commit: `git add GSDKit/Sources/GSDStore/TaskStore.swift && git commit -m "chore: inject Calendar into TaskStore for Phase 2 recurrence/presets"`

### Task B2: toggleComplete spawns a recurrence instance

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift` (new)

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreDepthTests {
    private let fixed = Date(timeIntervalSince1970: 1_700_000_000)

    private func utcCalendar() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func makeStore() throws -> (TaskStore, GRDBTaskRepository) {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory(), now: { Date(timeIntervalSince1970: 1_700_000_000) })
        var ids = ["spawned-id", "spawned-id-2"]
        let store = TaskStore(
            repository: repo,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            newID: { ids.isEmpty ? "fallback" : ids.removeFirst() },
            calendar: utcCalendar()
        )
        return (store, repo)
    }

    private func dueDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        return utcCalendar().date(from: c)!
    }

    @Test func completingRecurringTaskSpawnsAdvancedInstance() async throws {
        let (store, repo) = try makeStore()
        let original = Task(id: "orig", title: "Standup", urgent: true, important: true,
                            createdAt: fixed, updatedAt: fixed,
                            dueDate: dueDate(2026, 1, 31), recurrence: .monthly,
                            subtasks: [Subtask(id: "s1", title: "review", completed: true)])
        try await repo.upsert(original)
        try await store.toggleComplete(original)

        // Original is now completed and retained.
        let done = try #require(try await repo.fetch(id: "orig"))
        #expect(done.completed && done.completedAt == fixed)

        // A new instance exists with the advanced (clamped) due date + reset subtasks.
        let spawned = try #require(try await repo.fetch(id: "spawned-id"))
        #expect(spawned.completed == false)
        #expect(spawned.recurrence == .monthly)
        #expect(spawned.parentTaskId == "orig")
        let cal = utcCalendar()
        let due = cal.dateComponents([.year, .month, .day], from: try #require(spawned.dueDate))
        #expect((due.year, due.month, due.day) == (2026, 2, 28)) // Jan 31 + 1mo clamp
        #expect(spawned.subtasks.allSatisfy { !$0.completed })
    }

    @Test func completingNonRecurringTaskSpawnsNothing() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "One-off", urgent: false, important: false,
                        createdAt: fixed, updatedAt: fixed, recurrence: .none)
        try await repo.upsert(task)
        try await store.toggleComplete(task)
        #expect(try await repo.fetch(id: "spawned-id") == nil)
        #expect(try await repo.fetchAll().count == 1)
    }

    @Test func uncompletingRecurringTaskDoesNotSpawn() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Standup", urgent: true, important: true,
                        completed: true, completedAt: fixed,
                        createdAt: fixed, updatedAt: fixed,
                        dueDate: dueDate(2026, 1, 31), recurrence: .monthly)
        try await repo.upsert(task)
        try await store.toggleComplete(task) // completing → completed becomes false
        #expect(try await repo.fetch(id: "orig")?.completed == false)
        #expect(try await repo.fetch(id: "spawned-id") == nil)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreDepthTests` → FAIL (no spawn yet — `spawned-id` is nil).

- [ ] **Step 3: Modify `toggleComplete`** in `TaskStore.swift`. Replace the Phase-1 body:
```swift
    public func toggleComplete(_ task: Task) async throws {
        var t = task
        let now = clock()
        let willComplete = !t.completed
        t.completed = willComplete
        t.completedAt = willComplete ? now : nil
        t.updatedAt = now
        try await repository.upsert(t)

        // Completing a recurring task spawns the next instance (product spec §6.5).
        guard willComplete,
              let next = RecurrenceEngine.spawnNext(from: t, now: now, newID: newID(), calendar: calendar)
        else { return }
        try await repository.upsert(next)
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreDepthTests` → PASS (3 tests). Also re-run `swift test --filter TaskStoreTests` → still PASS (Phase-1 behavior preserved).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift && git commit -m "feat: spawn recurrence instance when completing a recurring task"`

### Task B3: Snooze, time-tracking start/stop

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: extend `GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift`

- [ ] **Step 1: Add failing tests** to `TaskStoreDepthTests.swift`:
```swift
    @Test func snoozeSetsSnoozedUntilFromPreset() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Ping", urgent: true, important: false,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        try await store.snooze(task, by: .oneHour)
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.snoozedUntil == fixed.addingTimeInterval(60 * 60))
        #expect(updated.updatedAt == fixed)
    }

    @Test func snoozeIsClampedToOneYearMax() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Ping", urgent: true, important: false,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        // Custom interval beyond 1 year is clamped.
        try await store.snooze(task, by: .custom(FieldLimits.maxSnoozeInterval + 1_000_000))
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.snoozedUntil == fixed.addingTimeInterval(FieldLimits.maxSnoozeInterval))
    }

    @Test func startTimerAddsRunningEntry() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Work", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        try await store.startTimer(task)
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.timeEntries.count == 1)
        #expect(updated.timeEntries[0].endedAt == nil)
    }

    @Test func startingSecondTimerThrows() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Work", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.timeEntries = [TimeEntry(id: "te000001", startedAt: fixed)]
        try await repo.upsert(task)
        await #expect(throws: TimeTrackingError.alreadyRunning) {
            try await store.startTimer(task)
        }
    }

    @Test func stopTimerClosesEntryAndRecalculatesTimeSpent() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Work", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed)
        // Running entry started 5 minutes before "now".
        task.timeEntries = [TimeEntry(id: "te000001", startedAt: fixed.addingTimeInterval(-300))]
        try await repo.upsert(task)
        try await store.stopTimer(task)
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.timeEntries[0].endedAt == fixed)
        #expect(updated.timeSpent == 5)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreDepthTests` → FAIL (`snooze`/`startTimer`/`stopTimer` not found).

- [ ] **Step 3: Add to `TaskStore`** in `TaskStore.swift`. First a snooze-preset type (top of file, after imports):
```swift
/// Snooze durations (product spec §6.7). `.custom` supports arbitrary intervals
/// (clamped to `FieldLimits.maxSnoozeInterval`).
public enum SnoozePreset: Equatable, Sendable {
    case fifteenMinutes, thirtyMinutes, oneHour, threeHours, tomorrow, nextWeek
    case custom(TimeInterval)

    public var interval: TimeInterval {
        switch self {
        case .fifteenMinutes: 15 * 60
        case .thirtyMinutes:  30 * 60
        case .oneHour:        60 * 60
        case .threeHours:     3 * 60 * 60
        case .tomorrow:       24 * 60 * 60
        case .nextWeek:       7 * 24 * 60 * 60
        case .custom(let seconds): seconds
        }
    }
}
```
Then the mutations (inside `TaskStore`, in the Mutations section):
```swift
    /// Set `snoozedUntil = now + preset`, clamped to the 1-year max (product spec §6.7).
    public func snooze(_ task: Task, by preset: SnoozePreset) async throws {
        var t = task
        let now = clock()
        let interval = min(preset.interval, FieldLimits.maxSnoozeInterval)
        t.snoozedUntil = now.addingTimeInterval(interval)
        t.updatedAt = now
        try await repository.upsert(t)
    }

    /// Start a time-tracking entry; rejects a second concurrent timer (product spec §6.9).
    public func startTimer(_ task: Task) async throws {
        var t = task
        let now = clock()
        t.timeEntries = try TimeTracking.start(t.timeEntries, now: now,
                                               newID: newID(size: IDGenerator.Size.timeEntry))
        t.updatedAt = now
        try await repository.upsert(t)
    }

    /// Stop the running entry and recalculate `timeSpent` (product spec §6.9).
    public func stopTimer(_ task: Task, notes: String? = nil) async throws {
        var t = task
        let now = clock()
        t.timeEntries = try TimeTracking.stop(t.timeEntries, now: now, notes: notes)
        t.timeSpent = TimeTracking.timeSpentMinutes(t.timeEntries)
        t.updatedAt = now
        try await repository.upsert(t)
    }
```

> **Note on `newID(size:)`:** the store's injected `newID` is a zero-arg `@Sendable () -> String` producing TASK-sized ids. Time entries need 8-char ids. Add a small private helper that uses `IDGenerator` directly for sized ids (it stays deterministic enough for tests, which assert the entry's `endedAt`/count, not its id):
```swift
    private func newID(size: Int) -> String {
        size == IDGenerator.Size.task ? newID() : IDGenerator.generate(size: size)
    }
```
This keeps the existing `newID()` injection point for task ids (tests rely on it) while giving time entries correctly-sized ids.

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreDepthTests` → PASS (8 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift && git commit -m "feat: add snooze and time-tracking start/stop to TaskStore"`


### Task B4: Subtask add/toggle/delete/reorder + dependency add/remove

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: extend `GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift`

- [ ] **Step 1: Add failing tests** to `TaskStoreDepthTests.swift`:
```swift
    @Test func addSubtaskAppendsIncompleteItem() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        try await repo.upsert(task)
        try await store.addSubtask(to: task, title: "Pack bags")
        let updated = try #require(try await repo.fetch(id: "orig"))
        #expect(updated.subtasks.map(\.title) == ["Pack bags"])
        #expect(updated.subtasks[0].completed == false)
        #expect(updated.updatedAt == fixed)
    }

    @Test func toggleSubtaskFlipsCompletion() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "s1", title: "Pack", completed: false)]
        try await repo.upsert(task)
        try await store.toggleSubtask(in: task, subtaskID: "s1")
        #expect(try await repo.fetch(id: "orig")?.subtasks.first?.completed == true)
    }

    @Test func deleteSubtaskRemovesIt() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "s1", title: "A"), Subtask(id: "s2", title: "B")]
        try await repo.upsert(task)
        try await store.deleteSubtask(in: task, subtaskID: "s1")
        #expect(try await repo.fetch(id: "orig")?.subtasks.map(\.id) == ["s2"])
    }

    @Test func moveSubtaskReorders() async throws {
        let (store, repo) = try makeStore()
        var task = Task(id: "orig", title: "Trip", urgent: false, important: true,
                        createdAt: fixed, updatedAt: fixed)
        task.subtasks = [Subtask(id: "s1", title: "A"), Subtask(id: "s2", title: "B"),
                         Subtask(id: "s3", title: "C")]
        try await repo.upsert(task)
        // Move the item at index 2 ("C") to the front.
        try await store.moveSubtask(in: task, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(try await repo.fetch(id: "orig")?.subtasks.map(\.id) == ["s3", "s1", "s2"])
    }

    @Test func addDependencyValidatesAndPersists() async throws {
        let (store, repo) = try makeStore()
        let now = fixed
        try await repo.upsert(Task(id: "A", title: "A", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        try await repo.upsert(Task(id: "B", title: "B", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        store.start()
        var waited = 0
        while store.tasks.count < 2 && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        let a = try #require(store.tasks.first { $0.id == "A" })
        try await store.addDependency("B", to: a)
        #expect(try await repo.fetch(id: "A")?.dependencies == ["B"])
    }

    @Test func addDependencyRejectsCycle() async throws {
        let (store, repo) = try makeStore()
        let now = fixed
        // A depends on B already; adding A as a dependency of B closes a cycle.
        try await repo.upsert(Task(id: "A", title: "A", urgent: true, important: true,
                                   createdAt: now, updatedAt: now, dependencies: ["B"]))
        try await repo.upsert(Task(id: "B", title: "B", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        store.start()
        var waited = 0
        while store.tasks.count < 2 && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        let b = try #require(store.tasks.first { $0.id == "B" })
        await #expect(throws: DependencyError.cycle) {
            try await store.addDependency("A", to: b)
        }
    }

    @Test func removeDependencyDropsIt() async throws {
        let (store, repo) = try makeStore()
        let task = Task(id: "A", title: "A", urgent: true, important: true,
                        createdAt: fixed, updatedAt: fixed, dependencies: ["B", "C"])
        try await repo.upsert(task)
        try await store.removeDependency("B", from: task)
        #expect(try await repo.fetch(id: "A")?.dependencies == ["C"])
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreDepthTests` → FAIL (the new methods don't exist).

- [ ] **Step 3: Add to `TaskStore`** in `TaskStore.swift` (Mutations section):
```swift
    // MARK: Subtasks (product spec §6.6)

    public func addSubtask(to task: Task, title: String) async throws {
        var t = task
        t.subtasks.append(Subtask(id: newID(), title: title, completed: false))
        try await persist(t)
    }

    public func toggleSubtask(in task: Task, subtaskID: String) async throws {
        var t = task
        guard let index = t.subtasks.firstIndex(where: { $0.id == subtaskID }) else { return }
        t.subtasks[index].completed.toggle()
        try await persist(t)
    }

    public func deleteSubtask(in task: Task, subtaskID: String) async throws {
        var t = task
        t.subtasks.removeAll { $0.id == subtaskID }
        try await persist(t)
    }

    public func moveSubtask(in task: Task, fromOffsets: IndexSet, toOffset: Int) async throws {
        var t = task
        t.subtasks.move(fromOffsets: fromOffsets, toOffset: toOffset)
        try await persist(t)
    }

    // MARK: Dependencies (product spec §6.8)

    /// Add a dependency edge after validating it against the live graph (no
    /// self-reference, the id must exist, no cycle). Throws `DependencyError` on rejection.
    public func addDependency(_ dependencyID: String, to task: Task) async throws {
        let graph = DependencyGraph(tasks: tasks)
        try graph.validateAdd(dependency: dependencyID, to: task.id)
        var t = task
        guard !t.dependencies.contains(dependencyID) else { return }
        t.dependencies.append(dependencyID)
        try await persist(t)
    }

    public func removeDependency(_ dependencyID: String, from task: Task) async throws {
        var t = task
        t.dependencies.removeAll { $0 == dependencyID }
        try await persist(t)
    }

    /// Shared write path: stamp `updatedAt` and upsert. (Subtask/dependency edits do
    /// not re-validate field limits here — the editor's Save path does, via `save`.)
    private func persist(_ task: Task) async throws {
        var t = task
        t.updatedAt = clock()
        try await repository.upsert(t)
    }
```

> **`Foundation` import:** `IndexSet`/`IndexSet.move` and `addingTimeInterval` require `import Foundation`, already present at the top of `TaskStore.swift` from Phase 1.

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreDepthTests` → PASS (15 tests). Re-run the full store suite: `swift test --filter 'TaskStore'` → all green.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreDepthTests.swift && git commit -m "feat: add subtask and dependency mutations to TaskStore"`

> **Milestone after Group B:** the store exposes the full Phase-2 mutation surface (recurrence-on-complete, snooze, timer start/stop, subtask CRUD+reorder, dependency add-with-cycle-check/remove), all `swift test`-verified, all stamping `updatedAt`. Dependency cleanup-on-delete is already handled by the Phase-0 repository (`GRDBTaskRepository.delete`); a store-level test for it lives in the existing Phase-1 suite.

---

## Group C — Editor extensions (`TaskEditorView`, build-verified via `xcodebuild`)

> SwiftUI presentation; verified with `xcodegen generate && xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet` → `** BUILD SUCCEEDED **`. APIs to confirm at build (flag if they don't compile as written): `DatePicker(selection:displayedComponents:)` with an optional-binding shim, `.onMove` inside an editable `ForEach`, `EditButton`, `.searchable` on the dependency picker sheet.
>
> The editor is EXTENDED, not rewritten. Phase 1 fields (title/description/quadrant/tags) and the `init(request:)` + `save()` structure stay; new `@State` and `Section`s are added, and `save()` carries the new fields onto the task. Because the Phase-1 editor already starts an edit from the original `Task` and saves that mutated value, the new fields round-trip without wiping existing state.

### Task C1: RelativeDate helper (shared formatter)

**Files:** Create `App/Support/RelativeDate.swift`

A pure presentation helper used by both the editor (tracked readout) and the card (due-date string). No store dependency; build-verified.

- [ ] **Step 1: Write it:**
```swift
import Foundation

/// Relative due-date phrasing for cards (product spec §6.10): "Due today",
/// overdue, or a relative future string. `reference` (now) is injected so the
/// caller controls the clock; the calendar defaults to `.current`.
enum RelativeDate {
    enum DueState { case overdue, today, upcoming }

    static func state(for dueDate: Date, reference: Date = .now, calendar: Calendar = .current) -> DueState {
        if calendar.isDate(dueDate, inSameDayAs: reference) { return .today }
        return dueDate < calendar.startOfDay(for: reference) ? .overdue : .upcoming
    }

    /// DAY-granular phrasing for DUE DATES (product spec §6.10): "Due today",
    /// "in 3 days", "2 days ago". Both dates are floored to start-of-day.
    static func dueString(for dueDate: Date, reference: Date = .now, calendar: Calendar = .current) -> String {
        switch state(for: dueDate, reference: reference, calendar: calendar) {
        case .today:
            return String(localized: "Due today")
        case .overdue, .upcoming:
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: calendar.startOfDay(for: dueDate),
                                             relativeTo: calendar.startOfDay(for: reference))
        }
    }

    /// TIME-granular remaining phrasing for SNOOZE (product spec §6.7): "in 1 hr",
    /// "in 45 min". Must NOT floor to start-of-day — the four short presets
    /// (15m/30m/1h/3h) land on the same calendar day, and snooze must show remaining
    /// time, not "Due today" (acceptance criterion A10).
    static func remainingString(until date: Date, reference: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: reference)
    }
}
```
- [ ] **Step 2: Build** → SUCCEEDED.
- [ ] **Step 3: Commit:** `git add App/Support/RelativeDate.swift GSD.xcodeproj && git commit -m "feat: add relative due-date helper"`

### Task C2: Editor — due date (DatePicker + preset chips) + recurrence picker

**Files:** Modify `App/Editor/TaskEditorView.swift`

- [ ] **Step 1:** Add `@State` for the new fields (alongside the Phase-1 `@State`s). In `TaskEditorView`:
```swift
    @State private var dueDate: Date?
    @State private var recurrence: RecurrenceType
    @State private var snoozedUntil: Date?
    @State private var estimateText: String
```
Initialize them in BOTH `init` branches. `.new`:
```swift
            _dueDate = State(initialValue: nil)
            _recurrence = State(initialValue: .none)
            _snoozedUntil = State(initialValue: nil)
            _estimateText = State(initialValue: "")
```
`.edit(let t)`:
```swift
            _dueDate = State(initialValue: t.dueDate)
            _recurrence = State(initialValue: t.recurrence)
            _snoozedUntil = State(initialValue: t.snoozedUntil)
            _estimateText = State(initialValue: t.estimatedMinutes.map(String.init) ?? "")
```

- [ ] **Step 2:** Add the due-date + recurrence `Section`s to the `Form` (after the Quadrant section). The due-date toggle uses an optional-binding shim so "None" is representable:
```swift
                Section(String(localized: "Due Date")) {
                    Toggle(String(localized: "Has due date"), isOn: Binding(
                        get: { dueDate != nil },
                        set: { dueDate = $0 ? (dueDate ?? Calendar.current.startOfDay(for: .now)) : nil }
                    ))
                    if dueDate != nil {
                        DatePicker(String(localized: "Due"),
                                   selection: Binding(get: { dueDate ?? .now }, set: { dueDate = $0 }),
                                   displayedComponents: .date)
                    }
                    HStack {
                        ForEach(DueDatePreset.allCases, id: \.self) { preset in
                            Button(preset.label) {
                                dueDate = DueDatePresets.resolve(preset, today: .now, calendar: .current)
                            }
                            .buttonStyle(.bordered)
                            .font(.caption)
                        }
                    }
                }
                Section(String(localized: "Repeat")) {
                    Picker(String(localized: "Recurrence"), selection: $recurrence) {
                        ForEach(RecurrenceType.allCases, id: \.self) { kind in
                            Text(recurrenceLabel(kind)).tag(kind)
                        }
                    }
                }
```
and a small label helper on the view:
```swift
    private func recurrenceLabel(_ kind: RecurrenceType) -> String {
        switch kind {
        case .none:    String(localized: "Never")
        case .daily:   String(localized: "Daily")
        case .weekly:  String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }
```

- [ ] **Step 3:** Carry the fields into `save()`. In BOTH branches (after the Phase-1 assignments), set:
```swift
        // (edit branch — mutating `task = original`)
        task.dueDate = dueDate
        task.recurrence = recurrence
        task.snoozedUntil = snoozedUntil
        task.estimatedMinutes = FieldLimits.normalizedEstimate(Int(estimateText))
```
For the `.new` branch, pass them through the `Task(...)` initializer instead (it already takes `dueDate:`/`recurrence:`; add `snoozedUntil:` and `estimatedMinutes: FieldLimits.normalizedEstimate(Int(estimateText))`). Editing `dueDate` resetting reminder state (§6.3) is a Phase-4 concern (no reminder UI yet) — note it as a TODO; do not implement reminder resets now.

- [ ] **Step 4: Build** → SUCCEEDED. **Commit:** `git add App/Editor/TaskEditorView.swift GSD.xcodeproj && git commit -m "feat: add due-date presets and recurrence picker to editor"`

### Task C3: Editor — inline reorderable subtasks + estimate + tracked readout

**Files:** Modify `App/Editor/TaskEditorView.swift`

- [ ] **Step 1:** Add subtask `@State` and init it in both branches:
```swift
    @State private var subtasks: [Subtask]      // .new → [], .edit → t.subtasks
    @State private var subtaskDraft = ""
```

- [ ] **Step 2:** Add the subtasks + estimate `Section`s:
```swift
                Section(String(localized: "Subtasks")) {
                    ForEach($subtasks) { $subtask in
                        HStack {
                            Button {
                                subtask.completed.toggle()
                            } label: {
                                Image(systemName: subtask.completed ? "checkmark.circle.fill" : "circle")
                            }
                            .buttonStyle(.plain)
                            TextField(String(localized: "Subtask"), text: $subtask.title)
                                .strikethrough(subtask.completed)
                        }
                    }
                    .onDelete { subtasks.remove(atOffsets: $0) }
                    .onMove { subtasks.move(fromOffsets: $0, toOffset: $1) }
                    HStack {
                        TextField(String(localized: "Add subtask"), text: $subtaskDraft)
                            .onSubmit(addSubtask)
                        Button(String(localized: "Add"), action: addSubtask)
                            .disabled(subtaskDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                      || subtasks.count >= FieldLimits.maxSubtasks)
                    }
                }
                Section(String(localized: "Estimate")) {
                    HStack {
                        TextField(String(localized: "Minutes"), text: $estimateText)
                            .keyboardType(.numberPad)
                        Spacer()
                        Text(trackedReadout).font(.caption).foregroundStyle(trackedColor)
                    }
                }
                Section(String(localized: "Snooze")) {
                    if let snoozedUntil, snoozedUntil > .now {
                        HStack {
                            Text(RelativeDate.remainingString(until: snoozedUntil))
                            Spacer()
                            Button(String(localized: "Clear"), role: .destructive) {
                                self.snoozedUntil = nil
                            }
                        }
                    }
                    Menu(String(localized: "Snooze for…")) {
                        ForEach(snoozeMenuPresets, id: \.0) { label, preset in
                            Button(label) {
                                snoozedUntil = Date.now.addingTimeInterval(
                                    min(preset.interval, FieldLimits.maxSnoozeInterval))
                            }
                        }
                    }
                }
```
> This finishes the `snoozedUntil` plumbing added in C2: the editor lists snooze (per the §6.3 "every field" editor contract) and there is no dead state. It sets `snoozedUntil` directly (no store round-trip) because `save()` already persists the field; the card/swipe path (Group D) is the quick action. `snoozeMenuPresets` is the same six-preset list defined in Group D — extract it to a shared file-scope `let` or duplicate the small array here (six entries; duplication is clearer than a cross-file dependency for a UI literal).

with the supporting members:
```swift
    private func addSubtask() {
        let title = subtaskDraft.trimmingCharacters(in: .whitespaces)
        subtaskDraft = ""
        guard !title.isEmpty, subtasks.count < FieldLimits.maxSubtasks else { return }
        subtasks.append(Subtask(id: IDGenerator.generate(size: IDGenerator.Size.task),
                                title: String(title.prefix(FieldLimits.subtaskTitleRange.upperBound)),
                                completed: false))
    }

    /// "Tracked Xm of Ym estimated" — over-estimate styled in the alert color (§6.9).
    private var trackedMinutes: Int { TimeTracking.timeSpentMinutes(original?.timeEntries ?? []) }
    private var trackedReadout: String {
        let tracked = TimeTracking.format(minutes: trackedMinutes)
        guard let estimate = Int(estimateText), estimate > 0 else {
            return String(localized: "Tracked \(tracked)")
        }
        return String(localized: "Tracked \(tracked) of \(TimeTracking.format(minutes: estimate))")
    }
    private var trackedColor: Color {
        guard let estimate = Int(estimateText), estimate > 0 else { return .secondary }
        return trackedMinutes > estimate ? .red : .secondary
    }

    /// The six §6.7 snooze presets, labels localized. (The matrix row in Group D
    /// uses the same list; a six-entry UI literal is clearer duplicated than shared.)
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes),
         (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour),
         (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow),
         (String(localized: "Next week"), .nextWeek)]
    }
```
> `SnoozePreset` lives in `GSDStore` (Group B3); the editor already `import GSDStore`, so the type and its `.interval` are in scope here.

Add `EditButton()` to the toolbar (so the subtask list is reorderable):
```swift
                ToolbarItem(placement: .topBarLeading) { EditButton() }
```

- [ ] **Step 3:** Carry `subtasks` into `save()` (both branches): `task.subtasks = subtasks`.

- [ ] **Step 4: Build** → SUCCEEDED. **Commit:** `git add App/Editor/TaskEditorView.swift GSD.xcodeproj && git commit -m "feat: add reorderable subtasks, estimate, tracked readout, and snooze to editor"`


### Task C4: Editor — dependency picker with LIVE cycle rejection

**Files:**
- Modify: `App/Editor/TaskEditorView.swift`
- Create: `App/Editor/DependencyPickerView.swift`

The picker presents the other tasks; any task that would create a cycle (or already a dependency, or self) is shown DISABLED with an explanation. The cycle check runs live against the current `[Task]` snapshot via `DependencyGraph`.

- [ ] **Step 1:** Create `App/Editor/DependencyPickerView.swift`:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// A searchable picker for adding a dependency. Disables any candidate that would
/// create a cycle (product spec §6.8), with an explanation. Runs the BFS check live.
struct DependencyPickerView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// The id of the task being edited and its current dependency ids.
    let editingTaskID: String
    let currentDependencies: [String]
    /// Called with the chosen dependency id.
    let onPick: (String) -> Void

    @State private var query = ""

    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }

    private var candidates: [Task] {
        store.tasks.filter { task in
            task.id != editingTaskID &&
            (query.isEmpty || task.title.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        NavigationStack {
            List(candidates) { task in
                let alreadyDep = currentDependencies.contains(task.id)
                let wouldCycle = graph.wouldCreateCycle(adding: task.id, to: editingTaskID)
                let disabled = alreadyDep || wouldCycle
                Button {
                    onPick(task.id)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                        if disabled {
                            Text(alreadyDep
                                 ? String(localized: "Already a dependency")
                                 : String(localized: "Would create a cycle"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(disabled)
            }
            .searchable(text: $query)
            .navigationTitle(String(localized: "Add Dependency"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
            }
        }
    }
}
```

- [ ] **Step 2:** In `TaskEditorView`, add dependency `@State` (init in both branches: `.new → []`, `.edit → t.dependencies`) and a presentation flag:
```swift
    @State private var dependencies: [String]
    @State private var showingDependencyPicker = false
```
Add the Dependencies `Section`:
```swift
                Section(String(localized: "Dependencies")) {
                    ForEach(dependencies, id: \.self) { depID in
                        HStack {
                            Text(store.tasks.first { $0.id == depID }?.title
                                 ?? String(localized: "Unknown task"))
                            Spacer()
                            Button(role: .destructive) {
                                dependencies.removeAll { $0 == depID }
                            } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                        }
                    }
                    Button(String(localized: "Add dependency…")) { showingDependencyPicker = true }
                        .disabled(dependencies.count >= FieldLimits.maxDependencies)
                }
```
Present the picker (alongside the existing `.presentationDetents`):
```swift
        .sheet(isPresented: $showingDependencyPicker) {
            DependencyPickerView(
                editingTaskID: editingTaskID,
                currentDependencies: dependencies,
                onPick: { dependencies.append($0) }
            )
        }
```
where `editingTaskID` resolves to the original id when editing, or a freshly-reserved id when creating. To keep the id stable across the picker's cycle checks for a NEW task, reserve it once in `init`:
```swift
    private let editingTaskID: String
    // .new branch:  editingTaskID = IDGenerator.generate(size: IDGenerator.Size.task)
    // .edit branch: editingTaskID = t.id
```
and in the `.new` branch of `save()`, pass `id: editingTaskID` to the `Task(...)` initializer (instead of generating a fresh id there) so the dependency graph the editor validated against matches the persisted task.

- [ ] **Step 3:** Carry `dependencies` into `save()` (both branches): `task.dependencies = dependencies`.

> **Live rejection is structural:** because the picker disables cycle-creating candidates up front, `save()` cannot persist a cycle. The store's `addDependency` (Group B) re-validates as defense-in-depth, but the editor path writes `dependencies` directly through `save()` → `store.save`, so the picker is the guard. If a future refactor routes edits through `addDependency`, the `DependencyError.cycle` throw is the backstop.

- [ ] **Step 4: Build** → SUCCEEDED. **Commit:** `git add App/Editor/ GSD.xcodeproj && git commit -m "feat: add dependency picker with live cycle rejection to editor"`

> **Milestone after Group C:** the editor exposes every Phase-2 field — due date (DatePicker + preset chips), recurrence, reorderable subtasks, dependency picker with live cycle-rejection, estimate, a tracked-vs-estimate readout, and a snooze menu — and Save still validates limits + disables on empty title (A13). Snooze is also available as a quick action from the card/swipe (Group D), per §6.7.

---

## Group D — Card extensions + action wiring (build-verified via `xcodebuild`)

> The visible payoff. APIs to confirm at build: `TimelineView(.periodic(from:by:))` for the live-ticking timer, `ProgressView(value:total:)` for the subtask bar, `.accessibilityActions` for the new VoiceOver custom actions (snooze, start/stop timer). The card stays store-free (a pure view of a `Task`); the live clock is injected so it stays previewable and deterministic.

### Task D1: TaskCardView — due date, recurrence, subtask bar, dependency badges, timer, snooze

**Files:** Modify `App/Matrix/TaskCardView.swift`

The Phase-1 card (title, description, tags, completion circle) stays. Add indicator rows. The card takes an optional injected `now` clock (default `.now`) for the live timer; the matrix passes a `TimelineView`-driven date so the running timer ticks each second.

- [ ] **Step 1:** Extend `TaskCardView`. Add a metadata footer below the tags, computed from the task. Insert after the tags `HStack` (inside the leading `VStack`):
```swift
                // --- Phase 2 indicators ---
                metadataRow
                if !task.subtasks.isEmpty { subtaskProgress }
```
and add the supporting members + an injected clock:
```swift
    /// Injected for the live-ticking timer + deterministic previews.
    var now: Date = .now
    /// Counts for dependency badges, supplied by the enclosing section from the
    /// live graph (keeps the card store-free). Defaults to no badges.
    var blockedByCount: Int = 0
    var blockingCount: Int = 0

    private var isBlocked: Bool { blockedByCount > 0 }

    @ViewBuilder private var metadataRow: some View {
        let runningStart = TimeTracking.runningEntry(task.timeEntries)?.startedAt
        HStack(spacing: 10) {
            if let dueDate = task.dueDate {
                Label(RelativeDate.dueString(for: dueDate, reference: now),
                      systemImage: "calendar")
                    .foregroundStyle(dueColor(for: dueDate))
            }
            if task.recurrence != .none {
                Image(systemName: "repeat").accessibilityLabel(String(localized: "Repeats"))
            }
            if blockedByCount > 0 {
                Label("\(blockedByCount)", systemImage: "lock")
                    .accessibilityLabel(String(localized: "Blocked by \(blockedByCount)"))
            }
            if blockingCount > 0 {
                Label("\(blockingCount)", systemImage: "arrow.right.circle")
                    .accessibilityLabel(String(localized: "Blocking \(blockingCount)"))
            }
            if let runningStart {
                // Live elapsed since the running entry started.
                let elapsedMinutes = Int(now.timeIntervalSince(runningStart) / 60.0)
                Label(TimeTracking.format(minutes: elapsedMinutes), systemImage: "stopwatch")
                    .foregroundStyle(.green)
            } else if let timeSpent = task.timeSpent, timeSpent > 0 {
                Label(TimeTracking.format(minutes: timeSpent), systemImage: "clock")
            }
            if let snoozedUntil = task.snoozedUntil, snoozedUntil > now {
                // Time-granular remaining (A10) — NOT dueString, which would floor to
                // the day and render "Due today" for the short presets.
                Label(RelativeDate.remainingString(until: snoozedUntil, reference: now),
                      systemImage: "moon.zzz")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    @ViewBuilder private var subtaskProgress: some View {
        let done = task.subtasks.filter(\.completed).count
        let total = task.subtasks.count
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: Double(done), total: Double(total))
                .tint(QuadrantStyle.accent(task.quadrant))
            Text("\(done)/\(total)").font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(done) of \(total) subtasks done"))
    }

    private func dueColor(for dueDate: Date) -> Color {
        switch RelativeDate.state(for: dueDate, reference: now) {
        case .overdue:  return .red
        case .today:    return .orange
        case .upcoming: return .secondary
        }
    }
```

- [ ] **Step 2:** De-emphasize blocked cards (§6.8). On the root `HStack`, add:
```swift
        .opacity(isBlocked && !task.completed ? 0.55 : 1)
```
and fold the new state into the VoiceOver label:
```swift
    private var accessibilityLabel: String {
        let state = task.completed ? String(localized: "completed") : String(localized: "active")
        var parts = ["\(task.title)", task.quadrant.title, state]
        if let dueDate = task.dueDate { parts.append(RelativeDate.dueString(for: dueDate, reference: now)) }
        if isBlocked { parts.append(String(localized: "blocked by \(blockedByCount)")) }
        return parts.joined(separator: ", ")
    }
```

- [ ] **Step 3: Build** → SUCCEEDED. **Commit:** `git add App/Matrix/TaskCardView.swift GSD.xcodeproj && git commit -m "feat: add due date, recurrence, subtasks, dependency, timer, snooze indicators to card"`

### Task D2: Wire live timer ticks + dependency counts in the section

**Files:** Modify `App/Matrix/QuadrantSection.swift` (and `QuadrantCell.swift` for iPad)

The card needs (a) a `now` that ticks each second when any visible task has a running timer, and (b) per-task blocked/blocking counts from the live graph. Compute both at the section level so the card stays pure.

- [ ] **Step 1:** Wrap each `TaskCardView` in a `TimelineView` and pass the graph-derived counts. In `QuadrantSection`'s row builder:
```swift
                ForEach(tasks) { task in
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        TaskCardView(
                            task: task,
                            now: context.date,
                            blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                            blockingCount: graph.blockedTasks(of: task.id).count
                        )
                    }
                    // ... existing swipe actions / tap / context menu unchanged ...
                }
```
where `graph` is computed once from the store snapshot:
```swift
    private var graph: DependencyGraph { DependencyGraph(tasks: store.tasks) }
```

> **Performance note:** `.periodic(by: 1)` re-renders the row each second. That is acceptable for the matrix's lazy lists (only on-screen rows tick). If a profiler later shows churn, gate the `TimelineView` behind "any task here has a running entry" — but YAGNI until measured.

- [ ] **Step 2:** Add the new actions to the row's swipe + context menu. Extend `TaskActions` (Phase 1) and the section to call them:
```swift
    // In TaskActions (Phase 1 struct), add:
    func snooze(_ t: Task, by preset: SnoozePreset) {
        _Concurrency.Task { try? await store.snooze(t, by: preset) }
    }
    func startTimer(_ t: Task) { _Concurrency.Task { try? await store.startTimer(t) } }
    func stopTimer(_ t: Task)  { _Concurrency.Task { try? await store.stopTimer(t) } }
```
Trailing swipe gains Snooze (a menu of the six §6.7 presets), and the context menu gains Start/Stop timer + Snooze:
```swift
            .swipeActions(edge: .trailing) {
                Button(String(localized: "Snooze")) { actions.snooze(task, by: .oneHour) }
                    .tint(.indigo)
                Button(role: .destructive) { actions.delete(task) } label: {
                    Label(String(localized: "Delete"), systemImage: "trash")
                }
            }
            .contextMenu {
                if TimeTracking.runningEntry(task.timeEntries) == nil {
                    Button(String(localized: "Start Timer")) { actions.startTimer(task) }
                } else {
                    Button(String(localized: "Stop Timer")) { actions.stopTimer(task) }
                }
                Menu(String(localized: "Snooze")) {
                    ForEach(snoozeMenuPresets, id: \.0) { label, preset in
                        Button(label) { actions.snooze(task, by: preset) }
                    }
                }
                // ... existing Edit / Complete / Move / Delete items unchanged ...
            }
            .accessibilityActions {
                Button(String(localized: "Snooze 1 hour")) { actions.snooze(task, by: .oneHour) }
                if TimeTracking.runningEntry(task.timeEntries) == nil {
                    Button(String(localized: "Start timer")) { actions.startTimer(task) }
                } else {
                    Button(String(localized: "Stop timer")) { actions.stopTimer(task) }
                }
            }
```
with the preset list as a view helper (the six §6.7 presets, labels localized):
```swift
    private var snoozeMenuPresets: [(String, SnoozePreset)] {
        [(String(localized: "15 minutes"), .fifteenMinutes),
         (String(localized: "30 minutes"), .thirtyMinutes),
         (String(localized: "1 hour"), .oneHour),
         (String(localized: "3 hours"), .threeHours),
         (String(localized: "Tomorrow"), .tomorrow),
         (String(localized: "Next week"), .nextWeek)]
    }
```

- [ ] **Step 3:** Mirror the `TimelineView`-wrap + dependency counts in the iPad `QuadrantCell.swift` card list (the context menu there already exists from Phase 1; add the same timer/snooze items).

- [ ] **Step 4: Build** both destinations:
```
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build -quiet
```
both → `** BUILD SUCCEEDED **`. Launch the iPhone sim, create a recurring task with a due date + subtasks, complete it (a fresh instance appears with the advanced due date), start a timer (the card ticks live), snooze from the trailing swipe (the snooze indicator shows remaining time). Capture a screenshot.
- [ ] **Step 5: Commit:** `git add App GSD.xcodeproj && git commit -m "feat: wire live timer, dependency counts, snooze and timer actions into matrix"`

> **Milestone after Group D:** the matrix surfaces every Phase-2 indicator and the row actions (snooze, start/stop timer) round-trip through the store. Recurrence spawn, snooze, and the live timer are all visible end-to-end on the simulator.

---

## Phase 2 — Definition of Done

Mapped to the increment spec's acceptance criteria (§10, A9–A13) and edge cases (§9). Every criterion maps to at least one passing test (A14).

- [ ] **A9 — Recurrence.** Completing a recurring task spawns the next instance with the correctly advanced due date (daily +1d / weekly +7d / monthly +1mo with month-end clamping) and reset subtasks; no-due-date stays none; instance-of-instance keeps single-level lineage.
  *Tests:* `RecurrenceEngineTests` (13: clamp non-leap/leap/30-day, weekly month boundary, daily, reset subtasks/reminder/time, root lineage, no-due-date, non-recurring nil); `TaskStoreDepthTests.completingRecurringTaskSpawnsAdvancedInstance`, `completingNonRecurringTaskSpawnsNothing`, `uncompletingRecurringTaskDoesNotSpawn`.
- [ ] **A10 — Snooze.** Snooze sets `snoozedUntil` from a §6.7 preset (15m/30m/1h/3h/Tomorrow/Next week), clamped to 1 year; the card shows **remaining time** (time-granular `RelativeDate.remainingString`, NOT the day-granular due string). Available from the editor menu (Group C3) and the card/swipe (Group D2).
  *Tests:* `TaskStoreDepthTests.snoozeSetsSnoozedUntilFromPreset`, `snoozeIsClampedToOneYearMax`. *Visual:* trailing-swipe snooze on the sim shows e.g. "in 1 hr" on the card snooze indicator (confirm it does NOT render "Due today" for short presets).
- [ ] **A11 — Dependencies.** The picker rejects an edge that would create a cycle (BFS), with an explanation; self-reference and missing-id rejected; blocked cards de-emphasized; delete scrubs the id from other tasks' dependencies.
  *Tests:* `DependencyGraphTests` (14: self/cycle/transitive/missing/queries/ready); `TaskStoreDepthTests.addDependencyRejectsCycle`, `addDependencyValidatesAndPersists`, `removeDependencyDropsIt`; Phase-1 `store_deleteTask_removesIdFromOtherDependencies`. *Visual:* disabled cycle candidate in the picker; dimmed blocked card.
- [ ] **A12 — Time tracking.** Start/stop produces a correct `timeSpent`; a running timer shows live elapsed; only one runs per task.
  *Tests:* `TimeTrackingTests` (8: start, reject-second, stop, reject-no-running, running-entry, sum-whole-minutes, floor-partial, format boundaries); `TaskStoreDepthTests.startTimerAddsRunningEntry`, `startingSecondTimerThrows`, `stopTimerClosesEntryAndRecalculatesTimeSpent`. *Visual:* live-ticking `stopwatch` label.
- [ ] **A13 — Editor validation + due-date presets.** The editor validates every limit and disables Save on empty title; due-date presets resolve per §6.10 (This week → Friday / next Friday on a weekend; Next week → Monday strictly after today, local TZ, firstWeekday-independent).
  *Tests:* `DueDatePresetsTests` (6, incl. firstWeekday-independence); existing Phase-1 `editor_emptyTitle_disablesSave` (carried; Save still disabled on empty title with the new fields present). *Build:* editor compiles with all new sections; Save path runs `TaskValidator.validate`.
- [ ] **A14 — Coverage.** Each criterion above maps to ≥1 passing test (listed). Run `cd GSDKit && swift test` → entire `GSDModel` + `GSDStore` suite green, sub-second, no simulator.
- [ ] **A15 — Accessibility (carried).** Dynamic Type at max + a VoiceOver pass on the matrix + editor: new indicators (due/recurrence/subtasks/dependency/timer/snooze) have VoiceOver labels; the new custom actions (snooze, start/stop timer) are reachable; no clipped fixed sizes.
- [ ] One commit per task; full `swift test` green before each store commit; both iPhone and iPad simulators build and launch.

---

## Self-review pass (spec coverage · placeholders · type consistency)

Performed against §2.1 scope, §5 contracts, §9 edge cases, and the real Phase-0/1 APIs. Findings folded inline above; the audit:

**Spec coverage (§6.5–6.10) — complete:**
- §6.5 recurrence: advance (daily/weekly/monthly clamp) + spawn (new id/timestamps, reset subtasks/completion/reminder, single-level lineage, no-due-date stays none) — Group A1/A2, store B2. ✔
- §6.6 subtasks: add/toggle/delete/reorder, progress bar + done/total — store B4, editor C3, card D1. ✔
- §6.7 snooze: six presets + 1-year clamp, remaining-time indicator — store B3, card D1, swipe/menu D2. ✔
- §6.8 dependencies: BFS cycle prevention (self/missing/cycle), blocking/uncompletedBlockers/isBlocked/blockedTasks/readyTasks, de-emphasis, cleanup-on-delete (Phase-0 repo) — Group A3, store B4, editor C4, card D1. ✔
- §6.9 time tracking: one running entry, stop recalculates whole-minute `timeSpent`, format `< 1m`/`Xm`/`Xh Ym`/`Xh`, live ticking, tracked-vs-estimate — Group A4, store B3, editor C3, card D1/D2. ✔
- §6.10 due dates: None/Today/This week/Next week (local TZ, firstWeekday-independent), DatePicker + chips, relative card string — Group A5, editor C2, card D1. ✔

**Edge cases (§9) — each has a named test:** Jan 31 +1mo (A1), weekly month boundary (A1), no-due-date spawn (A2), subtasks reset on spawn (A2), instance-of-instance lineage (A2); self-ref/cycle/missing-id rejected, readyTasks excludes incomplete blockers (A3); second-timer rejected, timeSpent sums completed only, format boundaries 0/<1m/60/61 (A4); This-week-on-weekend → next Friday, Next-week → Monday strictly after, TZ correctness (A5). ✔

**Placeholder scan:** no `TODO`/`FIXME`/`...`/`<placeholder>` in any implementation block. Real Swift in every step. (The one explicit deferral — reminder-state reset on due-date edit, §6.3 — is correctly flagged as a Phase-4 TODO comment, not a stub, because reminder UI does not exist yet.) ✔

**Type/API consistency vs. the real codebase:**
- `Task` init args match `Task.swift` exactly (incl. `notificationSent`/`lastNotificationAt`/`snoozedUntil`/`estimatedMinutes`/`timeSpent`/`timeEntries`). ✔
- `Subtask(id:title:completed:)`, `TimeEntry(id:startedAt:endedAt:notes:)` match. ✔
- `RecurrenceType.allCases`, `Quadrant.isUrgent/.isImportant/.title`, `IDGenerator.Size.{task,timeEntry}`, `FieldLimits.{maxSubtasks,maxDependencies,normalizedEstimate,maxSnoozeInterval,subtaskTitleRange}` all exist. ✔
- `TaskStore` extends its real Phase-1 shape (`repository`/`clock`/`newID`/`tasks`/`start()`); the new `calendar` param is appended + defaulted so Phase-1 call sites compile unchanged. ✔
- `GRDBTaskRepository.delete` already does dependency cleanup-on-delete — not re-implemented. ✔
- Concurrency: `_Concurrency.Task { }` used in app action closures and the test drain loops (files import `GSDModel`). ✔
- Regex: none of the new units use regex literals, so the `#/.../#` extended-delimiter caveat does not apply here (it remains relevant only to the Phase-1 `CaptureParser`). ✔
- `String(localized:)` used for all user-facing copy; interpolated localized strings (`"\(hours)h \(remainder)m"`, `"Blocked by \(n)"`) are valid `String(localized:)` forms. ✔

**Probe-verified logic (against Apple Swift 6.3.2, standalone scripts in `/tmp/p2-probe/`):**
1. Recurrence month-end clamping via `Calendar.date(byAdding: .month, value: 1)`: Jan 31 2026 → **Feb 28**; Jan 31 2024 → **Feb 29**; Mar 31 → **Apr 30**; weekly Jan 28 → **Feb 4**; daily Jan 31 → **Feb 1**. All correct.
2. BFS cycle detection: cycle-closing edge → **rejected**; transitive-but-acyclic → **allowed**; self-reference → **rejected**; redundant existing edge → **allowed**; `readyTasks` over A→B→C → **[C] only**. All correct.
3. Due-date preset weekday math AND `firstWeekday`-independence: This week → Friday (next Friday on Sat/Sun); Next week → Monday strictly after today (Sun → upcoming Monday, not +1 week); Sunday-first and Monday-first calendars **agree on all 7 weekdays**. All correct.
4. `timeSpent` sum-then-floor + format boundaries: 0 → "< 1m", 59 → "59m", 60 → "1h", 61 → "1h 1m", 125 → "2h 5m"; `Int(90/60)=1`, `Int(59/60)=0`, `Int(3661/60)=61`. All correct.

The pure spawn/struct-copy and snooze-clamp arithmetic were NOT separately scripted — they are plain Swift with no `Calendar`/locale subtlety the toolchain could surprise on, and are covered by the unit tests above.
