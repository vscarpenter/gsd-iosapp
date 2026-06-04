# Phase 3b — Organize Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the organization layer on top of 3a's filtering foundation — persisted **custom smart views** (+ pinning + criteria editor), **archive** (+ auto-archive), **search + ⌘K command palette**, and **bulk multi-select**. Local-only; sync is a Phase-5 documented TODO.

**Architecture:** Two new GRDB tables land behind versioned migrations (`registerV2` = `smartViews`, `registerV3` = `archivedTasks`), each with a record mapper and a repository mirroring `GRDBTaskRepository` (upsert/fetchAll/delete/observeAll). `FilterCriteria` (+ nested `Status`/`DateRange`) gains `Codable` so a view's criteria persist as a JSON column. Auto-archive is a pure, dependency-free unit in `GSDModel` (`AutoArchive.tasksToArchive`), red→green'd with an injected `Calendar`/`now` (boundary probe-verified). The single `@MainActor @Observable TaskStore` grows: smart-view CRUD + pinning (App-Group `UserDefaults`), archive/restore/delete + a launch sweep, and six bulk mutation methods. The app gains a criteria editor, an Archive list, `.searchable`, a ⌘K command palette, and `EditMode` multi-select with a bottom action bar.

**Tech Stack:** Swift 6 (toolchain Apple Swift 6.3.x), SwiftUI (Observation, `.searchable`, `.keyboardShortcut`, `EditMode`/`List(selection:)`), GSDKit (`GSDModel` zero-deps + `GSDStore` over GRDB), Swift Testing (`@Test`/`#expect`) for logic, `xcodebuild` for the app.

**Builds on (Phases 0–3a, committed on `main`):**
- `GSDModel`: `Task` (full §5.1 field set; short init compiles), `Subtask`, `Quadrant` (`String` enum, `init(urgent:important:)`, `CaseIterable`, Q1→Q4), `RecurrenceType` (`String` enum, `CaseIterable`), `DependencyGraph(tasks:)` (`uncompletedBlockers(of:)` resolves via `compactMap` — a **missing** id is silently dropped, never a blocker), **`FilterCriteria`** (+ nested `Status: Sendable, Equatable` enum and `DateRange` struct), **`TaskFilter.apply(_:to:now:calendar:)`**, **`SmartView`** (`id`/`name`/`icon`/`criteria`/`isBuiltIn`), **`BuiltInSmartViews.all`** (9 constants), `IDGenerator.Size.smartView = 12`, `TaskValidator.validate`, `ValidationError` (`.message`), `FieldLimits`.
- `GSDStore`: `AppDatabase` (`writer`, `inMemory()`, `live()`, `migrator` → `registerV1`), `Migrations.swift` (`registerV1` `tasks` table), `TaskRecord` (Codable/Fetchable/Persistable; `init(_:)` + `toDomain()`), `GSDJSON` (`string(_:)`/`value(_:_:)`, ms-truncating ISO-8601), `StoreLocation` (`appGroupID = "group.dev.vinny.gsd"`), `TaskRepository`/`GRDBTaskRepository` (observe via `ValueObservation` → `AsyncThrowingStream`), `TaskStore` (`@MainActor @Observable`; `tasks`, injected `clock`/`calendar`/`newID`, `start()` observe bridge, mutations, `tasks(in:showCompleted:)`, `tasks(matching:)`).
- App: `ContentView` (iPhone `TabView` Matrix·Browse; iPad `NavigationSplitView` sidebar Matrix + Smart Views → detail), `MatrixView`/`MatrixGridView`/`QuadrantSection`/`QuadrantCell`, `TaskListRow(task:blockedByCount:blockingCount:actions:onEdit:)`, `TaskActions(store:onCompleted:)`, `SmartViewListView`/`SmartViewRow(view:)`, `FilteredTaskListView(view:)`, `TaskEditorView(request:)`/`EditorRequest`, `QuadrantStyle.accent/.symbol`, `ConfettiView(trigger:)`, `AppPreferences.swift` (`UserDefaults.shared`, `AppGroup.id`), `Theme.swift` (`AppTheme`), `showCompletedToggle(_:)`.

**Reference:** design spec `docs/specs/2026-05-30-phase-3b-organize.md`; exemplar `docs/superpowers/plans/2026-05-30-phase-3a-filtering-navigation.md`; product spec `spec.md` (§5.6, §5.9, §6.13, §6.14).

---

## Architecture conventions locked by this plan (read first)

1. **`GSDModel` stays zero-dependency.** `AutoArchive.swift` and the `Codable` conformance on `FilterCriteria` link only `Foundation`. No GRDB, no SwiftUI.
2. **`GSDModel.Task` shadows Swift Concurrency's `Task`.** Use bare `Task` only as the domain type; in app/test concurrency use `_Concurrency.Task { }` (never bare `Task { }`).
3. **Inject time.** `AutoArchive.tasksToArchive` takes `now: Date` + `calendar: Calendar`; the store passes its injected `clock()`/`calendar`. Tests pin a fixed UTC gregorian calendar + fixed `now`. **The archive boundary is PROBE-VERIFIED** (see the probe note after Task C1a).
4. **Single store.** `TaskStore` is the one `@Observable` injected into the environment. It gains a `SmartViewRepository` + `ArchiveRepository` (each with its own `observeAll()` bridge mirroring the task observer) plus pinning/ArchiveSettings backed by App-Group `UserDefaults`. No second store type — keeps the environment + `waitForTasks` test pattern uniform.
5. **Repository owns only its cascade side-effects.** The store stamps `updatedAt = clock()` on every primary mutation; repositories stamp only rows they originate (none of the new repos cascade). Archive/restore preserve `updatedAt` as-is unless the operation is itself a mutation (restore stamps; archive copies the row verbatim + sets `archivedAt`).
6. **`Bool` filter flags: `false` = "don't constrain."** (Carried from 3a — the criteria editor must round-trip this.)
7. **Archive does NOT scrub dependents.** Archiving a completed task leaves its id in any dependent's `dependencies`. This is safe: only completed tasks archive, and `DependencyGraph.uncompletedBlockers` already (a) ignores completed blockers and (b) `compactMap`-drops ids not present in the snapshot — so a dependent's "ready to work" status is unaffected. Restore returns the row intact. Documented; not implemented as a cascade.
8. **UserDefaults lives in the store layer.** `GSDStore` gets its own App-Group accessor (`AppGroupDefaults`, reusing `StoreLocation.appGroupID`) so pinning + `ArchiveSettings` are store-owned and unit-testable with an injected `UserDefaults`. The App layer's `UserDefaults.shared` (in `AppPreferences.swift`) is unrelated and untouched.
9. **Accessibility + localization (carried):** Dynamic Type, VoiceOver labels, `String(localized:)` for ALL UI copy, ≥44pt targets.
10. **SwiftUI APIs are "confirm at build."** `.searchable`, `.keyboardShortcut("k", modifiers: .command)`, `List(selection:)` + `EditMode` multi-select + a bottom `.toolbar` action bar can't be `/tmp`-probed; they are verified via `xcodebuild` on both simulators (flag at build if they don't compile as written).

---

## Scope calls (from the approved spec; do not relitigate)

- **Custom views persist in a GRDB `smartViews` table** (`registerV2` + `SmartViewRecord` + `SmartViewRepository`); the 9 built-ins stay in-code constants (read-only). Browse/sidebar order: **pinned first → built-ins → custom**.
- **Pinning + ArchiveSettings in App-Group `UserDefaults`** (NOT GRDB): `pinnedSmartViewIds: [String]` (ordered, max 5), `archiveAutoEnabled: Bool`, `archiveAfterDays: Int` (30/60/90).
- **`archivedTasks` is a separate GRDB table** (`registerV3`), same columns as `tasks` + `archivedAt: Date`. `ArchiveRepository` owns archive/restore/delete/fetchAll/observe.
- **Auto-archive is pure logic** run on launch (and re-run when settings change); no in-app timer. Anchor = `startOfDay(now)`; archive when `completedAt < startOfDay(now) − N days`.
- **Criteria editor** exposes every editable §5.9 field; built-ins are not editable.
- **Command palette (⌘K)**: one sheet, search field + sectioned results (Tasks/Smart Views/Actions/Navigation), case-insensitive substring match (not fuzzy). Invoked by ⌘K + a toolbar magnifying-glass.
- **Search**: `.searchable` on the filtered lists + Archive, feeding `FilterCriteria.searchQuery` via `TaskFilter`.
- **Bulk multi-select**: `EditMode` selection on filtered lists + archive; a bottom `BulkActionBar` (Complete, Move, Add tags, Remove tags, Set due, Delete→confirm); each op iterates, validates, stamps `updatedAt`, goes through the store.
- **Sync deferral**: mutations persist locally; Phase-5 sync-enqueue is a documented TODO.

---

## File Structure

```
GSDKit/Sources/GSDModel/
├─ FilterCriteria.swift          # MODIFIED: + Codable on FilterCriteria/Status/DateRange; Status: String raw
├─ AutoArchive.swift             # NEW: pure tasksToArchive(_:afterDays:now:calendar:)
└─ (3a files otherwise unchanged)

GSDKit/Tests/GSDModelTests/
├─ FilterCriteriaCodableTests.swift   # NEW
└─ AutoArchiveTests.swift             # NEW

GSDKit/Sources/GSDStore/
├─ Migrations.swift              # MODIFIED: + registerV2 (smartViews), registerV3 (archivedTasks)
├─ SmartViewRecord.swift         # NEW: GRDB record for a custom view (criteria JSON)
├─ SmartViewRepository.swift     # NEW: protocol + GRDBSmartViewRepository
├─ ArchivedTaskRecord.swift      # NEW: GRDB record (TaskRecord columns + archivedAt)
├─ ArchiveRepository.swift       # NEW: protocol + GRDBArchiveRepository
├─ AppGroupDefaults.swift        # NEW: store-layer App-Group UserDefaults accessor + keys
├─ SmartViewPinning.swift        # NEW: pure ordered-pin helper (testable, no UserDefaults)
└─ TaskStore.swift               # MODIFIED: + customViews/allViews, CRUD, pinning, archive, sweep, 6 bulk methods

GSDKit/Tests/GSDStoreTests/
├─ MigrationTests.swift          # MODIFIED: + v2/v3 fresh + existing-DB
├─ SmartViewRecordTests.swift    # NEW
├─ SmartViewRepositoryTests.swift# NEW
├─ ArchiveRepositoryTests.swift  # NEW
├─ SmartViewPinningTests.swift   # NEW
├─ TaskStoreSmartViewTests.swift # NEW
├─ TaskStoreArchiveTests.swift   # NEW
└─ TaskStoreBulkTests.swift      # NEW

App/
├─ ContentView.swift             # MODIFIED: pinned+custom in Browse/sidebar; Archive entry; ⌘K + palette
├─ Browse/
│  ├─ SmartViewListView.swift    # MODIFIED: pinned → built-in → custom sections; "+" to create; edit/delete custom; .searchable hooks
│  ├─ FilteredTaskListView.swift # MODIFIED: .searchable + EditMode selection + BulkActionBar
│  └─ SmartViewEditorView.swift  # NEW: criteria editor (Group B)
├─ Archive/
│  └─ ArchiveListView.swift      # NEW: read-only dimmed cards; swipe Restore/Delete; .searchable; EditMode bulk
├─ Palette/
│  └─ CommandPaletteView.swift   # NEW: sectioned ⌘K palette (Group D)
└─ Bulk/
   └─ BulkActionBar.swift        # NEW: bottom toolbar of 6 ops (Group E)
```

---

## Group A — Smart-view persistence + CRUD + pinning (`GSDModel`/`GSDStore`, `swift test` + App build)

> Pure/logic tasks run from the package root: `cd GSDKit && swift test --filter <SuiteName>`. The Browse-wiring task (A7) is build-verified.

### Task A1: Make `FilterCriteria` (+ `Status` + `DateRange`) `Codable`

**Files:**
- Modify: `GSDKit/Sources/GSDModel/FilterCriteria.swift`
- Test: `GSDKit/Tests/GSDModelTests/FilterCriteriaCodableTests.swift` (new)

The criteria persist as a JSON column via `GSDJSON` (the same ms-truncating ISO-8601 strategy used by `TaskRecord`). `Status` gets a `String` raw value so its JSON is stable/human-readable like `Quadrant`/`RecurrenceType`. **PROBE-VERIFIED** (see note after this task).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/FilterCriteriaCodableTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct FilterCriteriaCodableTests {
    // Mirror GSDStore's GSDJSON ms-truncating ISO-8601 strategy so the round-trip
    // exercises the SAME date coding the smartViews JSON column will use.
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer(); try c.encode(FilterCriteriaCodableTests.formatter().string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = FilterCriteriaCodableTests.formatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()
    private func roundTrip(_ c: FilterCriteria) throws -> FilterCriteria {
        try decoder.decode(FilterCriteria.self, from: try encoder.encode(c))
    }
    // ms-clean dates (DatePicker .date values are midnight → ms-clean; no truncation loss).
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let end   = Date(timeIntervalSince1970: 1_700_604_800)

    @Test func defaultsRoundTrip() throws {
        let c = FilterCriteria()
        #expect(try roundTrip(c) == c)
    }
    @Test func fullyPopulatedRoundTrips() throws {
        let c = FilterCriteria(quadrants: [.urgentImportant, .notUrgentImportant], status: .active,
                               tags: ["home", "work"], dueDateRange: .init(start: start, end: end),
                               overdue: true, dueToday: true, dueThisWeek: true, noDueDate: true,
                               recurrence: [.daily, .weekly, .monthly], recentlyAdded: true,
                               recentlyCompleted: true, readyToWork: true, searchQuery: "milk")
        #expect(try roundTrip(c) == c)
    }
    @Test func openEndedRangeRoundTrips() throws {
        let c = FilterCriteria(status: .completed, dueDateRange: .init(start: start, end: nil))
        #expect(try roundTrip(c) == c)
    }
    @Test func statusEncodesAsStableString() throws {
        let json = String(decoding: try encoder.encode(FilterCriteria(status: .active)), as: UTF8.self)
        #expect(json.contains("\"status\":\"active\""))
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter FilterCriteriaCodableTests` → FAIL (`FilterCriteria` is not `Codable`; `Status` has no raw value).

- [ ] **Step 3: Edit `FilterCriteria.swift`.** Add `Codable` to the struct and both nested types, and give `Status` a `String` raw value. Replace the type declarations (the stored properties + `init` are UNCHANGED):
```swift
public struct FilterCriteria: Equatable, Sendable, Codable {
    public enum Status: String, Sendable, Equatable, Codable, CaseIterable { case all, active, completed }
    public struct DateRange: Equatable, Sendable, Codable {
        public var start: Date?
        public var end: Date?
        public init(start: Date? = nil, end: Date? = nil) { self.start = start; self.end = end }
    }
```
(`CaseIterable` on `Status` lets the Group B editor iterate it in a segmented Picker; `Sendable`/`Equatable` are carried.)

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter FilterCriteriaCodableTests` → PASS (4 tests). Re-run full `cd GSDKit && swift test` → still green (no 3a regression; `SmartView`/`BuiltInSmartViews` are unaffected — `SmartView` does NOT need `Codable`, only the persisted `criteria` does).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/FilterCriteria.swift GSDKit/Tests/GSDModelTests/FilterCriteriaCodableTests.swift && git commit -m "feat: make FilterCriteria Codable for JSON column storage"`

> **Probe note:** `FilterCriteria` Codable was verified through GSDJSON's exact encoder/decoder (ms-truncating `.withFractionalSeconds` ISO-8601) in `/tmp/p3b-probe/codable.swift` — 3/3 round-trips (defaults, fully-populated incl. nested `DateRange` + `[Quadrant]`/`[RecurrenceType]` arrays, open-ended range) passed equal; `Status` with a `String` raw value encodes as `"status":"active"`. Dates use ms-clean values (DatePicker `.date` yields midnight = ms-clean), so the ms-truncation is lossless in practice.

### Task A2: `SmartViewRecord` (GRDB record + domain mapping)

**Files:**
- Create: `GSDKit/Sources/GSDStore/SmartViewRecord.swift`
- Test: `GSDKit/Tests/GSDStoreTests/SmartViewRecordTests.swift` (new)

Mirrors `TaskRecord`: scalars map directly; `criteria` is a JSON string (via `GSDJSON`). A custom view always has `isBuiltIn = false`.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/SmartViewRecordTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct SmartViewRecordTests {
    @Test func recordRoundTripsToDomainAndBack() throws {
        let criteria = FilterCriteria(quadrants: [.urgentImportant], status: .active, tags: ["work"],
                                      dueThisWeek: true, recurrence: [.weekly], searchQuery: "report")
        let view = SmartView(id: "sv1", name: "My View", icon: "star",
                             criteria: criteria, isBuiltIn: false)
        let created = Date(timeIntervalSince1970: 1000)
        let updated = Date(timeIntervalSince1970: 2000)
        let record = try SmartViewRecord(view, createdAt: created, updatedAt: updated)
        #expect(record.isBuiltIn == false)
        #expect(record.id == "sv1")
        let back = try record.toDomain()
        #expect(back == view)
        #expect(back.criteria == criteria)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter SmartViewRecordTests` → FAIL (`SmartViewRecord` not found).

- [ ] **Step 3: Write `SmartViewRecord.swift`:**
```swift
import Foundation
import GRDB
import GSDModel

/// GRDB row for a CUSTOM smart view. Scalars map directly; `criteria` is stored as a
/// JSON string (same GSDJSON coding as TaskRecord's collections — increment spec §3.3).
/// `isBuiltIn` is persisted but is always `false` for stored rows (the 9 built-ins live
/// in-code as `BuiltInSmartViews.all` and are never written here).
struct SmartViewRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "smartViews"

    var id: String
    var name: String
    var icon: String
    var criteria: String      // JSON
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date
}

extension SmartViewRecord {
    init(_ view: SmartView, createdAt: Date, updatedAt: Date) throws {
        id = view.id
        name = view.name
        icon = view.icon
        criteria = try GSDJSON.string(view.criteria)
        isBuiltIn = false
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    func toDomain() throws -> SmartView {
        SmartView(id: id, name: name, icon: icon,
                  criteria: try GSDJSON.value(FilterCriteria.self, criteria),
                  isBuiltIn: false)
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter SmartViewRecordTests` → PASS.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/SmartViewRecord.swift GSDKit/Tests/GSDStoreTests/SmartViewRecordTests.swift && git commit -m "feat: add SmartViewRecord GRDB mapper with criteria JSON column"`

### Task A3: `registerV2` migration (`smartViews` table)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/Migrations.swift`
- Modify: `GSDKit/Tests/GSDStoreTests/MigrationTests.swift`

- [ ] **Step 1: Add the failing test** to `MigrationTests.swift` (covers fresh + existing DB, matching the v1 style):
```swift
    @Test func v2CreatesSmartViewsTable() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("smartViews"))
            let columns = Set(try d.columns(in: "smartViews").map(\.name))
            #expect(columns == ["id", "name", "icon", "criteria", "isBuiltIn", "createdAt", "updatedAt"])
        }
    }

    @Test func v2AppliesOverExistingV1DataWithoutLoss() throws {
        // Simulate an existing on-disk DB: run ONLY v1, insert a row, then run the full
        // migrator (v1+v2+v3) and confirm the task survives and smartViews now exists.
        let queue = try DatabaseQueue()
        var v1Only = DatabaseMigrator()
        AppDatabase.registerV1(&v1Only)
        try v1Only.migrate(queue)
        try queue.write { d in
            try d.execute(sql: """
                INSERT INTO tasks (id, title, urgent, important, quadrant, completed, createdAt, updatedAt, recurrence, tags, subtasks, dependencies, notificationEnabled, notificationSent, timeEntries)
                VALUES ('keep', 'Keep me', 0, 0, 'not-urgent-not-important', 0, '1970-01-01T00:00:00.000Z', '1970-01-01T00:00:00.000Z', 'none', '[]', '[]', '[]', 1, 0, '[]')
                """)
        }
        _ = try AppDatabase(queue)   // runs the full migrator over the existing DB
        try queue.read { d in
            #expect(try d.tableExists("smartViews"))
            #expect(try Int.fetchOne(d, sql: "SELECT COUNT(*) FROM tasks WHERE id = 'keep'") == 1)
        }
    }
```
Add `import GSDModel` is not needed here (raw SQL); the existing `import GRDB` + `@testable import GSDStore` already cover `DatabaseQueue`, `DatabaseMigrator`, `AppDatabase`.

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter MigrationTests` → FAIL (`smartViews` table missing).

- [ ] **Step 3: Edit `Migrations.swift`.** Register v2 in `migrator` and add `registerV2`:
```swift
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        return migrator
    }
```
and append after `registerV1`:
```swift
    static func registerV2(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v2") { db in
            try db.create(table: "smartViews") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("icon", .text).notNull()
                t.column("criteria", .text).notNull()          // FilterCriteria JSON
                t.column("isBuiltIn", .boolean).notNull().defaults(to: false)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
            }
        }
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter MigrationTests` → PASS (3 tests). The pre-existing `v1CreatesTasksTableWithFullColumnSet` stays green (it asserts only the `tasks` column set, which v2 does not touch).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/Migrations.swift GSDKit/Tests/GSDStoreTests/MigrationTests.swift && git commit -m "feat: add registerV2 smartViews migration"`

### Task A4: `SmartViewRepository` (CRUD + observe)

**Files:**
- Create: `GSDKit/Sources/GSDStore/SmartViewRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/SmartViewRepositoryTests.swift` (new)

Mirrors `GRDBTaskRepository`: an async boundary with `upsert`/`fetchAll`/`delete`/`observeAll`. No cascade side-effects, so it does not need an injected clock (the store stamps `createdAt`/`updatedAt`).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/SmartViewRepositoryTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct SmartViewRepositoryTests {
    private func view(_ id: String, name: String = "V") -> SmartView {
        SmartView(id: id, name: name, icon: "star",
                  criteria: FilterCriteria(status: .active), isBuiltIn: false)
    }
    private let t0 = Date(timeIntervalSince1970: 0)

    @Test func upsertThenFetchAll() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        try await repo.upsert(view("a"), createdAt: t0, updatedAt: t0)
        let all = try await repo.fetchAll()
        #expect(all.map(\.id) == ["a"])
        #expect(all.first?.isBuiltIn == false)
    }
    @Test func upsertUpdatesExistingRow() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        try await repo.upsert(view("a", name: "Old"), createdAt: t0, updatedAt: t0)
        try await repo.upsert(view("a", name: "New"), createdAt: t0, updatedAt: t0)
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.name == "New")
    }
    @Test func deleteRemovesRow() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        try await repo.upsert(view("a"), createdAt: t0, updatedAt: t0)
        try await repo.delete(id: "a")
        #expect(try await repo.fetchAll().isEmpty)
    }
    @Test func observeAllEmitsInitialThenOnInsert() async throws {
        let repo = GRDBSmartViewRepository(try AppDatabase.inMemory())
        var iterator = repo.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try await repo.upsert(view("x"), createdAt: t0, updatedAt: t0)
        var observed = try await iterator.next()
        while observed?.isEmpty == true { observed = try await iterator.next() }
        #expect(observed?.count == 1)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter SmartViewRepositoryTests` → FAIL (`GRDBSmartViewRepository` not found).

- [ ] **Step 3: Write `SmartViewRepository.swift`:**
```swift
import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for CUSTOM smart views. Holds no business rules; the
/// caller (TaskStore) stamps `createdAt`/`updatedAt`. Ordered by `updatedAt` desc to
/// match the task repository's convention.
public protocol SmartViewRepository: Sendable {
    func upsert(_ view: SmartView, createdAt: Date, updatedAt: Date) async throws
    func fetchAll() async throws -> [SmartView]
    func delete(id: String) async throws
    func observeAll() -> AsyncThrowingStream<[SmartView], Error>
}

public final class GRDBSmartViewRepository: SmartViewRepository {
    private let dbWriter: any DatabaseWriter
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.smartview-observer")

    public init(_ database: AppDatabase) { self.dbWriter = database.writer }

    public func upsert(_ view: SmartView, createdAt: Date, updatedAt: Date) async throws {
        let record = try SmartViewRecord(view, createdAt: createdAt, updatedAt: updatedAt)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func fetchAll() async throws -> [SmartView] {
        try await dbWriter.read { db in
            try SmartViewRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func delete(id: String) async throws {
        _ = try await dbWriter.write { db in try SmartViewRecord.deleteOne(db, key: id) }
    }

    public func observeAll() -> AsyncThrowingStream<[SmartView], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try SmartViewRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
            }
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: observerQueue),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter SmartViewRepositoryTests` → PASS (4 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/SmartViewRepository.swift GSDKit/Tests/GSDStoreTests/SmartViewRepositoryTests.swift && git commit -m "feat: add SmartViewRepository (CRUD + observe)"`

### Task A5: Pure pin-ordering helper + App-Group defaults accessor

**Files:**
- Create: `GSDKit/Sources/GSDStore/SmartViewPinning.swift`
- Create: `GSDKit/Sources/GSDStore/AppGroupDefaults.swift`
- Test: `GSDKit/Tests/GSDStoreTests/SmartViewPinningTests.swift` (new)

The ordered-pin rules (append, ignore dupes, cap at 5, unpin, reorder) are pure and deserve their own red→green unit; the store just persists the result through `AppGroupDefaults`.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/SmartViewPinningTests.swift`:
```swift
import Testing
@testable import GSDStore

struct SmartViewPinningTests {
    @Test func pinAppendsUpToFiveAndIgnoresDuplicates() {
        var pins: [String] = []
        for id in ["a", "b", "c", "d", "e", "f"] { pins = SmartViewPinning.pin(id, in: pins) }
        #expect(pins == ["a", "b", "c", "d", "e"])           // capped at 5; "f" rejected
        #expect(SmartViewPinning.pin("a", in: pins) == pins)  // duplicate is a no-op
    }
    @Test func unpinRemovesPreservingOrder() {
        #expect(SmartViewPinning.unpin("b", in: ["a", "b", "c"]) == ["a", "c"])
        #expect(SmartViewPinning.unpin("z", in: ["a", "b"]) == ["a", "b"])  // absent = no-op
    }
    @Test func reorderMovesWithinList() {
        // Move "c" (index 2) to the front (offset 0).
        #expect(SmartViewPinning.reorder(["a", "b", "c"], fromOffsets: [2], toOffset: 0) == ["c", "a", "b"])
    }
    @Test func maxIsFive() { #expect(SmartViewPinning.maxPins == 5) }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter SmartViewPinningTests` → FAIL (`SmartViewPinning` not found).

- [ ] **Step 3: Write `SmartViewPinning.swift`** (pure; no Foundation needed beyond `IndexSet`, which is Foundation — import it):
```swift
import Foundation

/// Pure ordered-pin rules (product spec §6.13): pinned views surface first, in pin
/// order, capped at `maxPins`. No persistence here — the store maps these over the
/// UserDefaults-backed `[String]` of pinned ids.
public enum SmartViewPinning {
    public static let maxPins = 5

    /// Append `id` if absent and under the cap; otherwise return `pins` unchanged.
    public static func pin(_ id: String, in pins: [String]) -> [String] {
        guard !pins.contains(id), pins.count < maxPins else { return pins }
        return pins + [id]
    }

    public static func unpin(_ id: String, in pins: [String]) -> [String] {
        pins.filter { $0 != id }
    }

    /// Reorder within the pinned list (drag-to-reorder). Mirrors `Array.move` semantics
    /// without importing SwiftUI (GSDStore stays SwiftUI-free).
    public static func reorder(_ pins: [String], fromOffsets: IndexSet, toOffset: Int) -> [String] {
        var copy = pins
        let moved = fromOffsets.sorted(by: >).map { idx -> String in
            let item = copy[idx]; copy.remove(at: idx); return item
        }.reversed()
        let shift = fromOffsets.filter { $0 < toOffset }.count
        copy.insert(contentsOf: moved, at: toOffset - shift)
        return copy
    }
}
```

- [ ] **Step 4: Write `AppGroupDefaults.swift`** (store-layer accessor + typed keys; reuses `StoreLocation.appGroupID`):
```swift
import Foundation

/// Store-layer App-Group `UserDefaults` for small UI/config state that is NOT task data
/// (pinning + archive settings — design-spec scope call). Falls back to `.standard` if
/// the group is unavailable (e.g. a plain simulator run without the entitlement). The
/// suite is injectable so the store's pinning/settings logic is unit-testable.
public enum AppGroupDefaults {
    public static let shared: UserDefaults =
        UserDefaults(suiteName: StoreLocation.appGroupID) ?? .standard

    public enum Key {
        public static let pinnedSmartViewIds = "pinnedSmartViewIds"
        public static let archiveAutoEnabled = "archiveAutoEnabled"
        public static let archiveAfterDays = "archiveAfterDays"
    }
}

/// Archive auto-sweep configuration (design-spec scope call): persisted in App-Group
/// UserDefaults, NOT a GRDB table. `afterDays` is constrained to the three offered values.
public struct ArchiveSettings: Equatable, Sendable {
    public var autoEnabled: Bool
    public var afterDays: Int        // 30 / 60 / 90
    public static let allowedDays = [30, 60, 90]
    public init(autoEnabled: Bool = false, afterDays: Int = 30) {
        self.autoEnabled = autoEnabled
        self.afterDays = ArchiveSettings.allowedDays.contains(afterDays) ? afterDays : 30
    }
}
```

- [ ] **Step 5: Run** `cd GSDKit && swift test --filter SmartViewPinningTests` → PASS (4 tests). Re-run full `cd GSDKit && swift test` → green.
- [ ] **Step 6: Commit:** `git add GSDKit/Sources/GSDStore/SmartViewPinning.swift GSDKit/Sources/GSDStore/AppGroupDefaults.swift GSDKit/Tests/GSDStoreTests/SmartViewPinningTests.swift && git commit -m "feat: add pure pin-ordering helper and App-Group defaults accessor"`

### Task A6: `TaskStore` smart-view CRUD + pinning

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreSmartViewTests.swift` (new)

The store gains an injected `SmartViewRepository` + an injected `UserDefaults` (defaults to `AppGroupDefaults.shared`), an observable `customViews: [SmartView]`, a derived `allViews`/`pinnedViews`, CRUD that stamps `createdAt`/`updatedAt` via the clock, and pinning persisted through the injected defaults. The smart-view observer mirrors the task observer; `start()` boots both.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreSmartViewTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreSmartViewTests {
    private let t0 = Date(timeIntervalSince1970: 0)
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        return TaskStore(repository: GRDBTaskRepository(db),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: suite,
                         clock: { Date(timeIntervalSince1970: 1000) },
                         newID: { "sv-fixed" },
                         calendar: .current)
    }
    private func waitForCustomViews(_ store: TaskStore, count: Int) async throws {
        store.start()
        var waited = 0
        while store.customViews.count != count && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
    }

    @Test func createPersistsCustomViewWithGeneratedIdAndStamps() async throws {
        let store = try makeStore()
        store.start()
        try await store.createView(name: "Mine", icon: "star", criteria: FilterCriteria(status: .active))
        try await waitForCustomViews(store, count: 1)
        #expect(store.customViews.first?.id == "sv-fixed")
        #expect(store.customViews.first?.isBuiltIn == false)
    }
    @Test func allViewsOrdersPinnedThenBuiltInsThenCustom() async throws {
        let store = try makeStore()
        try await store.createView(name: "Custom A", icon: "star", criteria: FilterCriteria())
        try await waitForCustomViews(store, count: 1)
        store.pin("overdue")                       // pin a built-in
        let ids = store.allViews.map(\.id)
        #expect(ids.first == "overdue")            // pinned surfaces first
        #expect(ids.contains("today-focus"))       // built-ins present
        #expect(ids.last == "sv-fixed")            // custom last
        #expect(ids.filter { $0 == "overdue" }.count == 1)  // pinned NOT duplicated in built-in section
    }
    @Test func pinPersistsToDefaultsAndCapsAtFive() async throws {
        let store = try makeStore()
        for id in ["a", "b", "c", "d", "e", "f"] { store.pin(id) }
        #expect(store.pinnedSmartViewIds == ["a", "b", "c", "d", "e"])
        store.unpin("a")
        #expect(store.pinnedSmartViewIds == ["b", "c", "d", "e"])
    }
    @Test func deleteRemovesCustomViewAndUnpins() async throws {
        let store = try makeStore()
        try await store.createView(name: "Mine", icon: "star", criteria: FilterCriteria())
        try await waitForCustomViews(store, count: 1)
        store.pin("sv-fixed")
        try await store.deleteView(id: "sv-fixed")
        try await waitForCustomViews(store, count: 0)
        #expect(store.pinnedSmartViewIds.contains("sv-fixed") == false)  // delete also unpins
    }
    @Test func updateViewRewritesCriteria() async throws {
        let store = try makeStore()
        try await store.createView(name: "Mine", icon: "star", criteria: FilterCriteria(status: .active))
        try await waitForCustomViews(store, count: 1)
        let edited = SmartView(id: "sv-fixed", name: "Renamed", icon: "bolt",
                               criteria: FilterCriteria(status: .completed), isBuiltIn: false)
        try await store.updateView(edited)
        // observer re-emits; poll for the rename
        var waited = 0
        while store.customViews.first?.name != "Renamed" && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(store.customViews.first?.name == "Renamed")
        #expect(store.customViews.first?.criteria.status == .completed)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreSmartViewTests` → FAIL (new init params + members not found). (`GRDBArchiveRepository` is created in C3 — implement A6 and C3's repo together if the suite won't compile; the smart-view assertions are what A6 must turn green.)

- [ ] **Step 3: Edit `TaskStore.swift` AND fix every existing constructor in the same edit.** Extend the stored properties + `init` to inject the two new repositories + defaults, add the observer, and add the CRUD/pinning API. **Because `init` gains required params, the three existing `GSDStoreTests` constructors (`TaskStoreTests`, `TaskStoreDepthTests`, `TaskStoreFilterTests`) stop compiling the instant this lands — and they share one test module with the new suite, so nothing in `GSDStoreTests` compiles until they're fixed.** Therefore the constructor updates (Step 3b below) are part of THIS step, not a later one — do them together so the target compiles before the green run.

  3a. Replace the stored-property block (lines under `public private(set) var tasks: [Task] = []`) and the `init` with:
```swift
    public private(set) var tasks: [Task] = []
    public private(set) var customViews: [SmartView] = []
    public private(set) var archivedTasks: [Task] = []

    private let repository: any TaskRepository
    private let smartViewRepository: any SmartViewRepository
    private let archiveRepository: any ArchiveRepository
    private let defaults: UserDefaults
    private let clock: @Sendable () -> Date
    private let newID: @Sendable () -> String
    private let calendar: Calendar
    // nonisolated(unsafe) so deinit can cancel without a MainActor hop.
    nonisolated(unsafe) private var observerTask: _Concurrency.Task<Void, Never>?
    nonisolated(unsafe) private var smartViewObserverTask: _Concurrency.Task<Void, Never>?
    nonisolated(unsafe) private var archiveObserverTask: _Concurrency.Task<Void, Never>?

    public init(
        repository: any TaskRepository,
        smartViewRepository: any SmartViewRepository,
        archiveRepository: any ArchiveRepository,
        defaults: UserDefaults = AppGroupDefaults.shared,
        clock: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> String = { IDGenerator.generate(size: IDGenerator.Size.smartView) },
        calendar: Calendar = .current
    ) {
        self.repository = repository
        self.smartViewRepository = smartViewRepository
        self.archiveRepository = archiveRepository
        self.defaults = defaults
        self.clock = clock
        self.newID = newID
        self.calendar = calendar
    }
```
> **Type-consistency note:** `newID` now defaults to `Size.smartView` (12). The existing task-creation paths (`add`, `create`) generate their OWN ids via `editingTaskID`/`newID()` where needed; the only callers that relied on the prior `Size.task` default were `add` and the recurrence spawn, which call `newID()` directly. Because both task ids and smart-view ids are opaque nanoid strings, length 12 vs 21 is cosmetic — but to avoid changing task-id length, leave the internal `newID(size:)` helper (which already special-cases `Size.task`) and have task-creation call sites that need a task id continue to pass through `newID()`. **Confirm at `swift test`:** the existing `TaskStoreTests`/`TaskStoreDepthTests` must stay green; if any asserts a 21-char id, override `newID:` in this plan's new tests only (they already inject `{ "sv-fixed" }`). The shipped app constructs the store without overriding `newID`, so production task ids become 12-char nanoids — acceptable (≥4 floor, still collision-safe) and uniform with view ids. If the team prefers task ids stay 21, split into two injected generators in a follow-up; YAGNI for 3b.

  3b. Extend `start()` to boot all three observers (idempotent each):
```swift
    /// Begin observing all repositories. Idempotent; call once from the app root.
    public func start() {
        startTaskObserver()
        startSmartViewObserver()
        startArchiveObserver()
    }

    private func startTaskObserver() {
        guard observerTask == nil else { return }
        let stream = repository.observeAll()
        observerTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.tasks = snapshot } } catch {}
        }
    }
    private func startSmartViewObserver() {
        guard smartViewObserverTask == nil else { return }
        let stream = smartViewRepository.observeAll()
        smartViewObserverTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.customViews = snapshot } } catch {}
        }
    }
    private func startArchiveObserver() {
        guard archiveObserverTask == nil else { return }
        let stream = archiveRepository.observeAll()
        archiveObserverTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.archivedTasks = snapshot } } catch {}
        }
    }
```
Replace the old single-observer `start()` (delete its body) and update `deinit`:
```swift
    deinit {
        observerTask?.cancel()
        smartViewObserverTask?.cancel()
        archiveObserverTask?.cancel()
    }
```

  3c. Add a `// MARK: Smart views` section (place after the `Reads` section):
```swift
    // MARK: Smart views (custom CRUD + pinning)

    /// Pinned ids first (in pin order), then the 9 built-ins, then custom views — with
    /// pinned ids de-duplicated out of their home section (product spec §6.13).
    public var allViews: [SmartView] {
        let everything = BuiltInSmartViews.all + customViews
        let byID = Dictionary(everything.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let pinned = pinnedSmartViewIds.compactMap { byID[$0] }
        let pinnedIDs = Set(pinned.map(\.id))
        let rest = everything.filter { !pinnedIDs.contains($0.id) }
        return pinned + rest
    }

    public var pinnedViews: [SmartView] {
        let byID = Dictionary((BuiltInSmartViews.all + customViews).map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        return pinnedSmartViewIds.compactMap { byID[$0] }
    }

    public func createView(name: String, icon: String, criteria: FilterCriteria) async throws {
        let now = clock()
        let view = SmartView(id: newID(), name: name, icon: icon, criteria: criteria, isBuiltIn: false)
        try await smartViewRepository.upsert(view, createdAt: now, updatedAt: now)
    }

    /// Update a custom view's name/icon/criteria, stamping `updatedAt` via the clock.
    /// `createdAt` is re-stamped to `now` on edit (the `SmartView` domain model doesn't
    /// carry it, and UI ordering uses `updatedAt`) — see the note below.
    public func updateView(_ view: SmartView) async throws {
        let now = clock()
        try await smartViewRepository.upsert(view, createdAt: now, updatedAt: now)
    }

    public func deleteView(id: String) async throws {
        try await smartViewRepository.delete(id: id)
        unpin(id)   // a deleted view can't stay pinned
    }

    // MARK: Pinning (App-Group UserDefaults; ordered, capped at SmartViewPinning.maxPins)

    public var pinnedSmartViewIds: [String] {
        defaults.stringArray(forKey: AppGroupDefaults.Key.pinnedSmartViewIds) ?? []
    }
    public func pin(_ id: String) {
        defaults.set(SmartViewPinning.pin(id, in: pinnedSmartViewIds),
                     forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
    }
    public func unpin(_ id: String) {
        defaults.set(SmartViewPinning.unpin(id, in: pinnedSmartViewIds),
                     forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
    }
    public func reorderPins(fromOffsets: IndexSet, toOffset: Int) {
        defaults.set(SmartViewPinning.reorder(pinnedSmartViewIds, fromOffsets: fromOffsets, toOffset: toOffset),
                     forKey: AppGroupDefaults.Key.pinnedSmartViewIds)
    }
```
> **Note on `updateView` `createdAt`:** `createdAt` is re-stamped to `now` on edit because the `SmartView` domain value doesn't carry it and 3b's UI orders by `updatedAt` only — so the value is observably unused. If a follow-up needs `createdAt` to be immutable, add `fetch(id:)` to `SmartViewRepository`, read the prior `createdAt`, and pass it through here; YAGNI for 3b. Documented.

  3d. **Fix the three existing `GSDStoreTests` constructors in the SAME commit** (they share the test module — none of `GSDStoreTests` compiles until all three are updated). `TaskStoreTests.swift`, `TaskStoreDepthTests.swift`, and `TaskStoreFilterTests.swift` each build `TaskStore(repository:...)` with the OLD signature. Update each `makeStore` helper to pass the new required params, preserving each test's existing `clock`/`calendar`/`newID` overrides, e.g.:
```swift
    private func makeStore() throws -> (TaskStore, GRDBTaskRepository) {
        let db = try AppDatabase.inMemory()
        let repo = GRDBTaskRepository(db, now: { Date(timeIntervalSince1970: 0) })
        let store = TaskStore(repository: repo,
                              smartViewRepository: GRDBSmartViewRepository(db),
                              archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                              defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                              clock: { Date(timeIntervalSince1970: 0) },
                              calendar: .current)
        return (store, repo)
    }
```
(There are exactly three call sites in the test target — confirmed by `grep -rl "TaskStore(" GSDKit/Tests`. The new bulk/archive methods added in C4/E1 are additive and don't cascade; this `init` change is the only breaking signature in the plan.)

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreSmartViewTests` → PASS (5 tests). Then re-run the full `cd GSDKit && swift test` → green (the three updated suites compile + pass with the new `init`). If the module fails to compile, a constructor was missed in Step 3d — fix before claiming green.

- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests && git commit -m "feat: add TaskStore smart-view CRUD, allViews ordering, and pinning"`

> **Production store construction** (`App/GSDApp.swift`) also uses the old `init`, but the App target is separate from `GSDStoreTests` and isn't built by `swift test`. That edit lands in Task A7 (which does the app build); `swift test` stays green here regardless.

> **Sequencing directive (REQUIRED):** The single-store decision means `TaskStore.init` takes `archiveRepository` as of A6, so A6's edit and tests reference `ArchiveRepository`/`GRDBArchiveRepository` + `ArchivedTaskRecord` + `registerV3` — all defined in Tasks **C1b–C3**. To keep `swift test` green at every commit, **land the archive *persistence layer* (C1b `ArchivedTaskRecord`, C2 `registerV3`, C3 `ArchiveRepository`) BEFORE A6.** Recommended execution order for the package layer: A1 → A2 → A3 → A4 → A5 → **C1b → C2 → C3** → **A6** → (then the rest of C's pure logic C1a + store archive methods C4 → C5). The plan keeps the C tasks documented under Group C for spec traceability, but the executor runs the three archive-persistence tasks in the A6 prerequisite slot. This is the one cross-group dependency; everything else follows the numeric order.

### Task A7: Wire custom + pinned views into Browse and the iPad sidebar (+ GSDApp construction)

**Files:**
- Modify: `App/GSDApp.swift`
- Modify: `App/Browse/SmartViewListView.swift`
- Modify: `App/ContentView.swift`

Build-verified UI. `SmartViewListView` switches from `BuiltInSmartViews.all` to the store's ordered `allViews`, sectioned **Pinned / Built-in / Custom**, with a "+" toolbar button (opens the Group B editor — wired in B1; A7 adds the button + state) and edit/delete affordances on custom rows. The iPad sidebar (`ContentView`) mirrors the same sections. Each custom row gets a pin/unpin context action.

> Build command (run after each UI task; run `xcodegen generate` first whenever a NEW file was added so the regenerated `GSD.xcodeproj` includes it):
> ```
> cd /Users/vinnycarpenter/Projects/gsd-iosapp
> xcodegen generate
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet ; echo "exit $?"
> xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build -quiet ; echo "exit $?"
> ```
> Exit 0 = success. If a simulator name is unavailable, run `xcrun simctl list devices available`, pick an equivalent iPhone / iPad-Pro device, and report which.

- [ ] **Step 1: Update `App/GSDApp.swift`** to construct the store with the new repositories. Replace the `init`:
```swift
    init() {
        // The local store is the app's source of truth; failure to open it is unrecoverable.
        let database = try! AppDatabase.live()
        _store = State(initialValue: TaskStore(
            repository: GRDBTaskRepository(database),
            smartViewRepository: GRDBSmartViewRepository(database),
            archiveRepository: GRDBArchiveRepository(database)
        ))
    }
```
(`defaults`/`clock`/`newID`/`calendar` keep their production defaults.)

- [ ] **Step 2: Rewrite `App/Browse/SmartViewListView.swift`** to read the store, section the views, and add create/edit/delete/pin affordances. `SmartViewRow` is unchanged (still `view:`-only). Replace the file body:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// Browse (iPhone tab): pinned views first, then built-ins, then custom — with a "+"
/// to create a custom view and per-custom-row edit/delete/pin actions.
struct SmartViewListView: View {
    @Environment(TaskStore.self) private var store
    @State private var editorTarget: SmartViewEditorTarget?

    var body: some View {
        NavigationStack {
            List {
                if !store.pinnedViews.isEmpty {
                    Section(String(localized: "Pinned")) {
                        ForEach(store.pinnedViews) { view in viewLink(view) }
                    }
                }
                Section(String(localized: "Built-in")) {
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        viewLink(view)
                    }
                }
                if !customRows.isEmpty {
                    Section(String(localized: "Custom")) {
                        ForEach(customRows) { view in viewLink(view) }
                    }
                }
            }
            .navigationTitle(String(localized: "Browse"))
            .navigationDestination(for: String.self) { id in
                if let view = store.allViews.first(where: { $0.id == id }) {
                    FilteredTaskListView(view: view)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                }
            }
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0) }
        }
    }

    /// Custom views not already shown in the Pinned section.
    private var customRows: [SmartView] {
        store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }
    }

    @ViewBuilder private func viewLink(_ view: SmartView) -> some View {
        NavigationLink(value: view.id) { SmartViewRow(view: view) }
            .swipeActions(edge: .leading) {
                if store.pinnedSmartViewIds.contains(view.id) {
                    Button { store.unpin(view.id) } label: {
                        Label(String(localized: "Unpin"), systemImage: "pin.slash")
                    }.tint(.gray)
                } else {
                    Button { store.pin(view.id) } label: {
                        Label(String(localized: "Pin"), systemImage: "pin")
                    }.tint(.orange)
                }
            }
            .swipeActions(edge: .trailing) {
                if !view.isBuiltIn {
                    Button(role: .destructive) {
                        _Concurrency.Task { try? await store.deleteView(id: view.id) }
                    } label: { Label(String(localized: "Delete"), systemImage: "trash") }
                    Button { editorTarget = .edit(view) } label: {
                        Label(String(localized: "Edit"), systemImage: "pencil")
                    }.tint(.blue)
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
> `SmartViewEditorTarget` (`.create` / `.edit(SmartView)`, `Identifiable`) and `SmartViewEditorView(target:)` are both defined in Task B1 (full code there). A7's Browse/sidebar edits reference them via `.sheet(item:)`, so **A7 and B1 build together: run B1 immediately after A7's `ContentView` edit and do the first `xcodebuild` at the end of B1.** (There is no standalone-stub step — the two tasks are one build unit; commit each separately as written.)

- [ ] **Step 3: Update the iPad sidebar in `App/ContentView.swift`.** In `RegularRootView`, read the store and replace the single `Section("Smart Views")` with the same Pinned/Built-in/Custom sections, and add a Smart-Views "+" + an Archive sidebar item (Archive detail wired in C). Replace `RegularRootView`:
```swift
private struct RegularRootView: View {
    @Environment(TaskStore.self) private var store
    private enum Item: Hashable { case matrix, archive, smartView(String) }
    @State private var selection: Item? = .matrix
    @State private var editorTarget: SmartViewEditorTarget?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label(String(localized: "Matrix"), systemImage: "square.grid.2x2").tag(Item.matrix)
                Label(String(localized: "Archive"), systemImage: "archivebox").tag(Item.archive)
                if !store.pinnedViews.isEmpty {
                    Section(String(localized: "Pinned")) {
                        ForEach(store.pinnedViews) { view in
                            SmartViewRow(view: view).tag(Item.smartView(view.id))
                        }
                    }
                }
                Section(String(localized: "Built-in")) {
                    ForEach(BuiltInSmartViews.all.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        SmartViewRow(view: view).tag(Item.smartView(view.id))
                    }
                }
                Section(String(localized: "Custom")) {
                    ForEach(store.customViews.filter { !store.pinnedSmartViewIds.contains($0.id) }) { view in
                        SmartViewRow(view: view).tag(Item.smartView(view.id))
                    }
                    Button { editorTarget = .create } label: {
                        Label(String(localized: "New Smart View"), systemImage: "plus")
                    }
                }
            }
            .navigationTitle("GSD")
            .sheet(item: $editorTarget) { SmartViewEditorView(target: $0) }
        } detail: {
            switch selection {
            case .smartView(let id):
                if let view = store.allViews.first(where: { $0.id == id }) {
                    NavigationStack { FilteredTaskListView(view: view) }
                } else {
                    MatrixGridView()
                }
            case .archive:
                NavigationStack { ArchiveListView() }
            case .matrix, .none:
                MatrixGridView()
            }
        }
    }
}
```
> `ArchiveListView` is built in Task C6 and `SmartViewEditorView` in B1; this `ContentView` edit therefore builds together with B1 + C6. Per the sequencing directive, implement B1 and C6 before the final A7/ContentView build, or stub both with empty `View`s to keep intermediate builds green and flesh out in their tasks.

- [ ] **Step 4: Build** (run `xcodegen generate` — new files from B1/C6 must exist first) both simulators → exit 0. Launch iPhone: Browse shows Pinned (after pinning)/Built-in/Custom sections, "+" opens the editor, swipes pin/edit/delete. Launch iPad: sidebar shows the same sections + an Archive item; selecting a view shows its filtered list. Screenshot both.
- [ ] **Step 5: Commit:** `git add App/GSDApp.swift App/Browse/SmartViewListView.swift App/ContentView.swift GSD.xcodeproj && git commit -m "feat: wire custom + pinned smart views into Browse and iPad sidebar"`

> **Milestone after Group A:** custom views persist (GRDB v2) and survive relaunch; pinning persists (UserDefaults) and surfaces first, capped at 5; built-ins stay read-only. `cd GSDKit && swift test` green; both simulators build. **Maps A20, A21.**

---

## Group B — Criteria editor (`SmartViewEditorView`) — App (`xcodebuild`)

### Task B1: `SmartViewEditorView` (create + edit a custom view)

**Files:**
- Create: `App/Browse/SmartViewEditorView.swift`

A `Form` binding a working `FilterCriteria` + name + icon. Every editable §5.9 field is exposed: quadrants (multi-select chips), status (segmented), tags (token field), due predicates (toggles: overdue / dueToday / dueThisWeek / noDueDate), `dueDateRange` (optional start/end DatePickers), recurrence (multi-select chips), readyToWork (toggle), searchQuery (text). Save validates a non-empty name (≤ 60 chars) and persists via `store.createView`/`store.updateView`. Built-ins never reach this editor. This task supplies `SmartViewEditorTarget` referenced by A7.

- [ ] **Step 1:** Write `App/Browse/SmartViewEditorView.swift`:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// What the smart-view editor sheet was opened to do. `Identifiable` drives `.sheet(item:)`.
enum SmartViewEditorTarget: Identifiable {
    case create
    case edit(SmartView)
    var id: String {
        switch self {
        case .create: "create"
        case .edit(let v): v.id
        }
    }
}

/// Create or edit a CUSTOM smart view: name + icon + a full FilterCriteria editor
/// (every editable §5.9 field). Built-ins are never editable (they never open this).
struct SmartViewEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var icon: String
    @State private var criteria: FilterCriteria
    @State private var tagDraft = ""
    @State private var hasStart: Bool
    @State private var hasEnd: Bool
    @State private var saveError: String?

    private let editingID: String?

    /// SF Symbols offered for a custom view (a small curated set; keeps the picker simple).
    private let iconChoices = ["star", "flag", "bolt", "tag", "tray.full", "list.bullet",
                               "calendar", "clock", "checkmark.circle", "exclamationmark.triangle"]
    private let maxNameLength = 60

    init(target: SmartViewEditorTarget) {
        switch target {
        case .create:
            _name = State(initialValue: "")
            _icon = State(initialValue: "star")
            _criteria = State(initialValue: FilterCriteria())
            _hasStart = State(initialValue: false)
            _hasEnd = State(initialValue: false)
            editingID = nil
        case .edit(let view):
            _name = State(initialValue: view.name)
            _icon = State(initialValue: view.icon)
            _criteria = State(initialValue: view.criteria)
            _hasStart = State(initialValue: view.criteria.dueDateRange?.start != nil)
            _hasEnd = State(initialValue: view.criteria.dueDateRange?.end != nil)
            editingID = view.id
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "Name")) {
                    TextField(String(localized: "Smart view name"), text: $name)
                        .onChange(of: name) { _, _ in saveError = nil }
                }
                Section(String(localized: "Icon")) { iconPicker }
                Section(String(localized: "Status")) { statusPicker }
                Section(String(localized: "Quadrants")) { quadrantChips }
                Section(String(localized: "Tags")) { tagField }
                Section(String(localized: "Due")) { duePredicateToggles }
                Section(String(localized: "Due date range")) { dueRangePickers }
                Section(String(localized: "Recurrence")) { recurrenceChips }
                Section { readyToggle }
                Section(String(localized: "Search text")) {
                    TextField(String(localized: "Contains…"), text: $criteria.searchQuery)
                }
                if let saveError {
                    Section { Text(saveError).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle(editingID == nil ? String(localized: "New Smart View") : String(localized: "Edit Smart View"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
    }

    private var iconPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(iconChoices, id: \.self) { choice in
                    Button { icon = choice } label: {
                        Image(systemName: choice)
                            .frame(width: 44, height: 44)
                            .background(icon == choice ? Color.accentColor.opacity(0.2) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel(choice)
                    .accessibilityAddTraits(icon == choice ? .isSelected : [])
                }
            }
        }
    }

    private var statusPicker: some View {
        Picker(String(localized: "Status"), selection: $criteria.status) {
            ForEach(FilterCriteria.Status.allCases, id: \.self) { status in
                Text(statusLabel(status)).tag(status)
            }
        }
        .pickerStyle(.segmented)
    }

    private var quadrantChips: some View {
        LazyVGrid(columns: [GridItem(), GridItem()], spacing: 8) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                let on = criteria.quadrants.contains(q)
                Button { toggle(q, in: \.quadrants) } label: {
                    Label(q.title, systemImage: QuadrantStyle.symbol(q))
                        .frame(maxWidth: .infinity).padding(8)
                        .background(on ? QuadrantStyle.accent(q).opacity(0.2) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                }
                .tint(QuadrantStyle.accent(q))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !criteria.tags.isEmpty {
                HStack {
                    ForEach(criteria.tags, id: \.self) { tag in
                        Button { criteria.tags.removeAll { $0 == tag } } label: { Text("#\(tag)  ✕").font(.caption2) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            TextField(String(localized: "Add tag"), text: $tagDraft).onSubmit(addTag)
        }
    }

    private var duePredicateToggles: some View {
        Group {
            Toggle(String(localized: "Overdue"), isOn: $criteria.overdue)
            Toggle(String(localized: "Due today"), isOn: $criteria.dueToday)
            Toggle(String(localized: "Due this week"), isOn: $criteria.dueThisWeek)
            Toggle(String(localized: "No due date"), isOn: $criteria.noDueDate)
        }
    }

    private var dueRangePickers: some View {
        Group {
            Toggle(String(localized: "From date"), isOn: $hasStart)
            if hasStart {
                DatePicker(String(localized: "Start"),
                           selection: Binding(get: { criteria.dueDateRange?.start ?? .now },
                                              set: { setRange(start: $0) }),
                           displayedComponents: .date)
            }
            Toggle(String(localized: "To date"), isOn: $hasEnd)
            if hasEnd {
                DatePicker(String(localized: "End"),
                           selection: Binding(get: { criteria.dueDateRange?.end ?? .now },
                                              set: { setRange(end: $0) }),
                           displayedComponents: .date)
            }
        }
        .onChange(of: hasStart) { _, on in if !on { setRange(start: nil) } else { setRange(start: criteria.dueDateRange?.start ?? .now) } }
        .onChange(of: hasEnd) { _, on in if !on { setRange(end: nil) } else { setRange(end: criteria.dueDateRange?.end ?? .now) } }
    }

    private var recurrenceChips: some View {
        HStack {
            ForEach([RecurrenceType.daily, .weekly, .monthly], id: \.self) { kind in
                let on = criteria.recurrence.contains(kind)
                Button { toggle(kind, in: \.recurrence) } label: {
                    Text(recurrenceLabel(kind))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(on ? Color.accentColor.opacity(0.2) : .clear,
                                    in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var readyToggle: some View {
        Toggle(String(localized: "Ready to work (no incomplete blockers)"), isOn: $criteria.readyToWork)
    }

    // MARK: Helpers

    private func toggle(_ value: Quadrant, in keyPath: WritableKeyPath<FilterCriteria, [Quadrant]>) {
        if criteria[keyPath: keyPath].contains(value) { criteria[keyPath: keyPath].removeAll { $0 == value } }
        else { criteria[keyPath: keyPath].append(value) }
    }
    private func toggle(_ value: RecurrenceType, in keyPath: WritableKeyPath<FilterCriteria, [RecurrenceType]>) {
        if criteria[keyPath: keyPath].contains(value) { criteria[keyPath: keyPath].removeAll { $0 == value } }
        else { criteria[keyPath: keyPath].append(value) }
    }
    private func setRange(start: Date) { setRange(start: .some(start)) }
    private func setRange(start: Date?) {
        var range = criteria.dueDateRange ?? .init()
        range.start = start
        criteria.dueDateRange = (range.start == nil && range.end == nil) ? nil : range
    }
    private func setRange(end: Date) { setRange(end: .some(end)) }
    private func setRange(end: Date?) {
        var range = criteria.dueDateRange ?? .init()
        range.end = end
        criteria.dueDateRange = (range.start == nil && range.end == nil) ? nil : range
    }
    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).lowercased()
        tagDraft = ""
        guard !t.isEmpty, FieldLimits.tagLengthRange.contains(t.count),
              !criteria.tags.contains(t), criteria.tags.count < FieldLimits.maxTags else { return }
        criteria.tags.append(t)
    }
    private func statusLabel(_ s: FilterCriteria.Status) -> String {
        switch s {
        case .all: String(localized: "All")
        case .active: String(localized: "Active")
        case .completed: String(localized: "Completed")
        }
    }
    private func recurrenceLabel(_ kind: RecurrenceType) -> String {
        switch kind {
        case .none: String(localized: "Never")
        case .daily: String(localized: "Daily")
        case .weekly: String(localized: "Weekly")
        case .monthly: String(localized: "Monthly")
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { saveError = String(localized: "Name is required."); return }
        guard trimmed.count <= maxNameLength else {
            saveError = String(localized: "Name must be 60 characters or fewer."); return
        }
        _Concurrency.Task { @MainActor in
            do {
                if let editingID {
                    try await store.updateView(SmartView(id: editingID, name: trimmed, icon: icon,
                                                          criteria: criteria, isBuiltIn: false))
                } else {
                    try await store.createView(name: trimmed, icon: icon, criteria: criteria)
                }
                dismiss()
            } catch {
                saveError = String(localized: "Couldn't save. Please try again.")
            }
        }
    }
}
```

- [ ] **Step 2: Build** (new file → `xcodegen generate` first) both simulators → exit 0. Launch iPhone: Browse "+" opens the editor; set name + a few criteria + a date range; Save creates a custom view that appears in the Custom section; tapping it shows results matching `TaskFilter`. Re-open via Edit on the custom row — the fields round-trip (status, quadrants, toggles, range, recurrence, search). Built-in rows have no Edit affordance. Screenshot the editor.
- [ ] **Step 3: Commit:** `git add App/Browse/SmartViewEditorView.swift GSD.xcodeproj && git commit -m "feat: add SmartViewEditorView criteria editor for custom views"`

> **Milestone after Group B:** every editable §5.9 field round-trips through save and produces a view whose results match `TaskFilter` (the same pure engine the editor's preview/count uses). **Maps A22.**

---

## Group C — Archive (`GSDModel` + `GSDStore` + App)

> **Execution order:** per the A6 sequencing directive, run **C1b → C2 → C3 before A6**, then C1a + C4 → C7 after A6. Tasks are numbered for spec traceability, not strict execution order.

### Task C1a: `AutoArchive.tasksToArchive` (pure logic)

**Files:**
- Create: `GSDKit/Sources/GSDModel/AutoArchive.swift`
- Test: `GSDKit/Tests/GSDModelTests/AutoArchiveTests.swift` (new)

Pure value-in/value-out. **Rule (PROBE-VERIFIED):** anchor = `startOfDay(now)`; cutoff = `startOfDay(now) − afterDays days`; a completed task archives when `completedAt < cutoff` (strictly older, exclusive `<`). Incomplete tasks and completed-but-`completedAt == nil` never archive. The function does NOT consult the enabled toggle — that gating lives in the store's sweep (Task C4).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDModelTests/AutoArchiveTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct AutoArchiveTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return cal.date(from: c)!
    }
    /// now = 2026-06-15 09:00 UTC → startOfDay = 2026-06-15 00:00 UTC.
    private var now: Date { day(2026, 6, 15, 9) }
    /// cutoff at N=30 = 2026-05-16 00:00 UTC.
    private var cutoff: Date { cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now))! }

    private func task(_ id: String, completed: Bool = true, completedAt: Date?) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: completed,
             completedAt: completedAt, createdAt: Date(timeIntervalSince1970: 0),
             updatedAt: Date(timeIntervalSince1970: 0))
    }
    private func ids(_ tasks: [Task], days: Int = 30) -> Set<String> {
        Set(AutoArchive.tasksToArchive(tasks, afterDays: days, now: now, calendar: cal).map(\.id))
    }

    @Test func exactlyAtCutoffIsNotArchived() {
        #expect(ids([task("at", completedAt: cutoff)]).isEmpty)
    }
    @Test func oneSecondBeforeCutoffIsArchived() {
        #expect(ids([task("before", completedAt: cutoff.addingTimeInterval(-1))]) == ["before"])
    }
    @Test func oneSecondAfterCutoffIsNotArchived() {
        #expect(ids([task("after", completedAt: cutoff.addingTimeInterval(1))]).isEmpty)
    }
    @Test func completedOnTheNDaysAgoDayIsNotArchived() {
        // 2026-05-16 at 09:00 wall-clock is AFTER cutoff midnight → not yet old enough.
        #expect(ids([task("wall", completedAt: day(2026, 5, 16, 9))]).isEmpty)
    }
    @Test func completedTheDayBeforeIsArchived() {
        #expect(ids([task("dayBefore", completedAt: day(2026, 5, 15, 23))]) == ["dayBefore"])
    }
    @Test func incompleteNeverArchived() {
        #expect(ids([task("active", completed: false, completedAt: nil)]).isEmpty)
    }
    @Test func completedWithNilTimestampNotArchived() {
        #expect(ids([task("noStamp", completedAt: nil)]).isEmpty)
    }
    @Test func recentlyCompletedNotArchived() {
        #expect(ids([task("recent", completedAt: day(2026, 6, 14, 12))]).isEmpty)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter AutoArchiveTests` → FAIL (`AutoArchive` not found).

- [ ] **Step 3: Write `AutoArchive.swift`:**
```swift
import Foundation

/// Pure auto-archive selection (design-spec scope call). A completed task is archived
/// when its `completedAt` is strictly older than `afterDays` days before the START OF
/// TODAY — i.e. `completedAt < startOfDay(now) − afterDays`. The anchor is `startOfDay`
/// (consistent with `TaskFilter`'s `overdue`), so the cutoff is stable across the day.
/// Incomplete tasks and completed-but-unstamped tasks never archive. The enabled toggle
/// is NOT consulted here — gating lives in the store's sweep. PROBE-VERIFIED boundary.
public enum AutoArchive {
    public static func tasksToArchive(_ tasks: [Task], afterDays days: Int,
                                      now: Date, calendar: Calendar) -> [Task] {
        let cutoff = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return tasks.filter { task in
            guard task.completed, let completedAt = task.completedAt else { return false }
            return completedAt < cutoff
        }
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter AutoArchiveTests` → PASS (8 tests).
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDModel/AutoArchive.swift GSDKit/Tests/GSDModelTests/AutoArchiveTests.swift && git commit -m "feat: add pure AutoArchive.tasksToArchive selection"`

> **Probe note:** the boundary was pinned in `/tmp/p3b-probe/autoarchive.swift` (8/8 assertions, fixed UTC gregorian calendar, now = 2026-06-15 09:00, cutoff = 2026-05-16 00:00): exactly-at-cutoff excluded; 1s-before archived; 1s-after excluded; the N-days-ago calendar day at 09:00 NOT archived (confirming anchor = `startOfDay`, not raw `now`); incomplete + nil-`completedAt` never archived.

### Task C1b: `ArchivedTaskRecord` (GRDB record)

**Files:**
- Create: `GSDKit/Sources/GSDStore/ArchivedTaskRecord.swift`
- Test: `GSDKit/Tests/GSDStoreTests/ArchiveRepositoryTests.swift` will cover it; add a focused round-trip test there in Task C3. (No separate test file — the record is exercised via the repository, mirroring how `TaskRecord` is covered by `TaskRepositoryTests` + `TaskRecordTests`. A dedicated `ArchivedTaskRecordTests` is optional; include one parallel to `TaskRecordTests` if you prefer — see Step 2.)

The archived record carries every `TaskRecord` column plus `archivedAt: Date`. To avoid duplicating the 24-field mapping, build it by composing `TaskRecord`: store the task columns identically and add `archivedAt`.

- [ ] **Step 1:** Write `ArchivedTaskRecord.swift`:
```swift
import Foundation
import GRDB
import GSDModel

/// GRDB row for an ARCHIVED task — the full §5.1 column set (identical to `tasks`) plus
/// `archivedAt`. Lives in a SEPARATE `archivedTasks` table so archived rows are excluded
/// from the matrix/smart-view queries by construction (design-spec scope call). The
/// task-column mapping is delegated to `TaskRecord` to avoid duplicating 24 fields.
struct ArchivedTaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "archivedTasks"

    var id: String
    var title: String
    var description: String
    var urgent: Bool
    var important: Bool
    var quadrant: String
    var completed: Bool
    var completedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    var dueDate: Date?
    var recurrence: String
    var tags: String
    var subtasks: String
    var dependencies: String
    var parentTaskId: String?
    var notifyBefore: Int?
    var notificationEnabled: Bool
    var notificationSent: Bool
    var lastNotificationAt: Date?
    var snoozedUntil: Date?
    var estimatedMinutes: Int?
    var timeSpent: Int?
    var timeEntries: String
    var archivedAt: Date
}

extension ArchivedTaskRecord {
    /// Build from a domain task + the archive timestamp. Reuses `TaskRecord` for the
    /// task-column JSON encoding so the two records stay in lockstep.
    init(_ task: Task, archivedAt: Date) throws {
        let r = try TaskRecord(task)
        id = r.id; title = r.title; description = r.description
        urgent = r.urgent; important = r.important; quadrant = r.quadrant
        completed = r.completed; completedAt = r.completedAt
        createdAt = r.createdAt; updatedAt = r.updatedAt; dueDate = r.dueDate
        recurrence = r.recurrence; tags = r.tags; subtasks = r.subtasks
        dependencies = r.dependencies; parentTaskId = r.parentTaskId
        notifyBefore = r.notifyBefore; notificationEnabled = r.notificationEnabled
        notificationSent = r.notificationSent; lastNotificationAt = r.lastNotificationAt
        snoozedUntil = r.snoozedUntil; estimatedMinutes = r.estimatedMinutes
        timeSpent = r.timeSpent; timeEntries = r.timeEntries
        self.archivedAt = archivedAt
    }

    /// Reconstruct the domain task (drops `archivedAt`, which is archive-only metadata).
    func toDomain() throws -> Task {
        let r = TaskRecord(id: id, title: title, description: description, urgent: urgent,
                           important: important, quadrant: quadrant, completed: completed,
                           completedAt: completedAt, createdAt: createdAt, updatedAt: updatedAt,
                           dueDate: dueDate, recurrence: recurrence, tags: tags, subtasks: subtasks,
                           dependencies: dependencies, parentTaskId: parentTaskId,
                           notifyBefore: notifyBefore, notificationEnabled: notificationEnabled,
                           notificationSent: notificationSent, lastNotificationAt: lastNotificationAt,
                           snoozedUntil: snoozedUntil, estimatedMinutes: estimatedMinutes,
                           timeSpent: timeSpent, timeEntries: timeEntries)
        return try r.toDomain()
    }
}
```
> **Type note:** `TaskRecord` is a `struct` with a memberwise initializer (it has no explicit `init`, only the `init(_ task:)` convenience extension + the synthesized `Codable` init). The memberwise `TaskRecord(id:title:...:timeEntries:)` IS available within the module (same target). **Confirm at `swift test`:** if the memberwise init is not synthesized because of the extension initializer, add an explicit memberwise `init` to `TaskRecord`, OR change `toDomain()` to map fields directly (copy `TaskRecord.toDomain`'s body inline). Flag at execution.

- [ ] **Step 2 (optional):** Add `ArchivedTaskRecordTests.swift` parallel to `TaskRecordTests` asserting `ArchivedTaskRecord(task, archivedAt:).toDomain() == task` and `archivedAt` is preserved. (The repository test in C3 also covers round-trip; this is belt-and-suspenders.)

- [ ] **Step 3: Build check via the package** — there is no behavior to test alone; it compiles when C3's repository uses it. Defer the commit to bundle with C2 + C3 (one commit per logical task is fine here since C1b/C2/C3 are the indivisible archive-persistence unit). **Commit:** done at the end of C3.

### Task C2: `registerV3` migration (`archivedTasks` table)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/Migrations.swift`
- Modify: `GSDKit/Tests/GSDStoreTests/MigrationTests.swift`

- [ ] **Step 1: Add the failing test** to `MigrationTests.swift`:
```swift
    @Test func v3CreatesArchivedTasksTableWithArchivedAt() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("archivedTasks"))
            let columns = Set(try d.columns(in: "archivedTasks").map(\.name))
            // Same 24 task columns + archivedAt.
            #expect(columns.contains("archivedAt"))
            #expect(columns.contains("id"))
            #expect(columns.contains("completedAt"))
            #expect(columns.count == 25)
            let indexed = Set(try d.indexes(on: "archivedTasks").flatMap(\.columns))
            #expect(indexed.contains("archivedAt"))
        }
    }
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter MigrationTests` → FAIL (`archivedTasks` missing).

- [ ] **Step 3: Edit `Migrations.swift`.** Add `registerV3(&migrator)` to `migrator` (after `registerV2`), and append:
```swift
    static func registerV3(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v3") { db in
            try db.create(table: "archivedTasks") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("urgent", .boolean).notNull()
                t.column("important", .boolean).notNull()
                t.column("quadrant", .text).notNull()
                t.column("completed", .boolean).notNull().defaults(to: false)
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
                t.column("dueDate", .datetime)
                t.column("recurrence", .text).notNull().defaults(to: "none")
                t.column("tags", .text).notNull().defaults(to: "[]")
                t.column("subtasks", .text).notNull().defaults(to: "[]")
                t.column("dependencies", .text).notNull().defaults(to: "[]")
                t.column("parentTaskId", .text)
                t.column("notifyBefore", .integer)
                t.column("notificationEnabled", .boolean).notNull().defaults(to: true)
                t.column("notificationSent", .boolean).notNull().defaults(to: false)
                t.column("lastNotificationAt", .datetime)
                t.column("snoozedUntil", .datetime)
                t.column("estimatedMinutes", .integer)
                t.column("timeSpent", .integer)
                t.column("timeEntries", .text).notNull().defaults(to: "[]")
                t.column("archivedAt", .datetime).notNull().indexed()
            }
        }
    }
```
And ensure the `migrator` computed property reads:
```swift
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        return migrator
    }
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter MigrationTests` → PASS (4 tests). The v2 existing-DB test now also implicitly proves v3 applies over an existing DB (the full migrator runs). Optionally extend `v2AppliesOverExistingV1DataWithoutLoss` to also `#expect(try d.tableExists("archivedTasks"))`.
- [ ] **Step 5: Commit:** deferred to end of C3 (bundled archive-persistence unit), OR commit now: `git add GSDKit/Sources/GSDStore/Migrations.swift GSDKit/Tests/GSDStoreTests/MigrationTests.swift && git commit -m "feat: add registerV3 archivedTasks migration"`

### Task C3: `ArchiveRepository` (archive/restore/delete/fetchAll/observe)

**Files:**
- Create: `GSDKit/Sources/GSDStore/ArchiveRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/ArchiveRepositoryTests.swift` (new)

`archive(_:)` writes an `ArchivedTaskRecord` (stamping `archivedAt = now`) AND deletes the task from the live `tasks` table in ONE transaction. `restore(_:)` does the inverse. `deletePermanently(id:)` removes the archived row. `fetchAll`/`observeAll` read archived tasks (newest archive first). The repo takes an injected `now` for `archivedAt`.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/ArchiveRepositoryTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct ArchiveRepositoryTests {
    private let t0 = Date(timeIntervalSince1970: 0)
    private func task(_ id: String) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: true,
             completedAt: t0, createdAt: t0, updatedAt: t0)
    }

    @Test func archiveMovesRowOutOfTasksIntoArchive() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 5000) })
        try await tasks.upsert(task("a"))
        try await archive.archive(task("a"))
        #expect(try await tasks.fetch(id: "a") == nil)          // gone from active
        let archived = try await archive.fetchAll()
        #expect(archived.map(\.id) == ["a"])                    // present in archive
    }
    @Test func restoreMovesRowBackToTasks() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        try await tasks.upsert(task("a"))
        try await archive.archive(task("a"))
        try await archive.restore(id: "a")
        #expect(try await tasks.fetch(id: "a")?.id == "a")      // back in active
        #expect(try await archive.fetchAll().isEmpty)           // gone from archive
    }
    @Test func deletePermanentlyRemovesArchivedRow() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        try await tasks.upsert(task("a"))
        try await archive.archive(task("a"))
        try await archive.deletePermanently(id: "a")
        #expect(try await archive.fetchAll().isEmpty)
        #expect(try await tasks.fetch(id: "a") == nil)          // not resurrected
    }
    @Test func archivedTasksAreIsolatedFromActiveFetch() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        try await tasks.upsert(task("keep"))
        try await tasks.upsert(task("gone"))
        try await archive.archive(task("gone"))
        #expect(try await tasks.fetchAll().map(\.id) == ["keep"])  // archive excluded from active
    }
    @Test func observeAllEmitsInitialThenOnArchive() async throws {
        let db = try AppDatabase.inMemory()
        let tasks = GRDBTaskRepository(db, now: { self.t0 })
        let archive = GRDBArchiveRepository(db, now: { self.t0 })
        var iterator = archive.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)
        try await tasks.upsert(task("x"))
        try await archive.archive(task("x"))
        var observed = try await iterator.next()
        while observed?.isEmpty == true { observed = try await iterator.next() }
        #expect(observed?.count == 1)
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter ArchiveRepositoryTests` → FAIL (`GRDBArchiveRepository` not found).

- [ ] **Step 3: Write `ArchiveRepository.swift`:**
```swift
import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for archived tasks. `archive`/`restore` move a row between
/// the `tasks` and `archivedTasks` tables in a single transaction so the two never both
/// hold (or both drop) the same id. `archivedAt` is stamped from the injected clock.
public protocol ArchiveRepository: Sendable {
    func archive(_ task: Task) async throws
    func restore(id: String) async throws
    func deletePermanently(id: String) async throws
    func fetchAll() async throws -> [Task]
    func observeAll() -> AsyncThrowingStream<[Task], Error>
}

public final class GRDBArchiveRepository: ArchiveRepository {
    private let dbWriter: any DatabaseWriter
    private let now: @Sendable () -> Date
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.archive-observer")

    public init(_ database: AppDatabase, now: @escaping @Sendable () -> Date = { Date() }) {
        self.dbWriter = database.writer
        self.now = now
    }

    public func archive(_ task: Task) async throws {
        let record = try ArchivedTaskRecord(task, archivedAt: now())
        try await dbWriter.write { db in
            try record.save(db)
            _ = try TaskRecord.deleteOne(db, key: task.id)
        }
    }

    public func restore(id: String) async throws {
        try await dbWriter.write { db in
            guard let archived = try ArchivedTaskRecord.fetchOne(db, key: id) else { return }
            let task = try archived.toDomain()
            try TaskRecord(task).save(db)
            _ = try ArchivedTaskRecord.deleteOne(db, key: id)
        }
    }

    public func deletePermanently(id: String) async throws {
        _ = try await dbWriter.write { db in try ArchivedTaskRecord.deleteOne(db, key: id) }
    }

    public func fetchAll() async throws -> [Task] {
        try await dbWriter.read { db in
            try ArchivedTaskRecord.order(Column("archivedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func observeAll() -> AsyncThrowingStream<[Task], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try ArchivedTaskRecord.order(Column("archivedAt").desc).fetchAll(db).map { try $0.toDomain() }
            }
            let cancellable = observation.start(
                in: dbWriter,
                scheduling: .async(onQueue: observerQueue),
                onError: { continuation.finish(throwing: $0) },
                onChange: { continuation.yield($0) }
            )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }
}
```

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter ArchiveRepositoryTests` → PASS (5 tests).
- [ ] **Step 5: Commit** (the archive-persistence unit C1b+C2+C3): `git add GSDKit/Sources/GSDStore/ArchivedTaskRecord.swift GSDKit/Sources/GSDStore/Migrations.swift GSDKit/Sources/GSDStore/ArchiveRepository.swift GSDKit/Tests/GSDStoreTests/MigrationTests.swift GSDKit/Tests/GSDStoreTests/ArchiveRepositoryTests.swift && git commit -m "feat: add ArchivedTaskRecord, registerV3, and ArchiveRepository"`

> **Now run Task A6** (TaskStore smart-view CRUD + pinning) — `GRDBArchiveRepository` now exists, so A6's store init + tests compile.

### Task C4: `TaskStore` archive methods + sweep + ArchiveSettings

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreArchiveTests.swift` (new)

The store exposes `archive(_:)`/`restore(_:)`/`deletePermanently(_:)`, the observable `archivedTasks` (wired in A6's observer), `runAutoArchiveSweep()` (reads `archiveSettings`; if disabled → no-op; else archives `AutoArchive.tasksToArchive(...)`), and `archiveSettings` get/set backed by the injected defaults.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreArchiveTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreArchiveTests {
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 9) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = h
        return cal.date(from: c)!
    }
    private var now: Date { day(2026, 6, 15, 9) }

    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        let suite = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let fixed = now
        return TaskStore(repository: GRDBTaskRepository(db, now: { fixed }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { fixed }),
                         defaults: suite,
                         clock: { fixed }, newID: { "id" }, calendar: cal)
    }
    private func completed(_ id: String, at when: Date) -> Task {
        Task(id: id, title: id, urgent: false, important: false, completed: true,
             completedAt: when, createdAt: day(2026, 1, 1), updatedAt: day(2026, 1, 1))
    }
    private func waitForTasks(_ store: TaskStore, count: Int) async throws {
        store.start(); var w = 0
        while store.tasks.count != count && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
    }
    private func waitForArchived(_ store: TaskStore, count: Int) async throws {
        var w = 0
        while store.archivedTasks.count != count && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
    }

    @Test func archiveThenRestoreRoundTrips() async throws {
        let store = try makeStore()
        try await store.create(completed("a", at: now))
        try await waitForTasks(store, count: 1)
        try await store.archive(store.tasks[0])
        try await waitForArchived(store, count: 1)
        #expect(store.tasks.isEmpty)
        try await store.restore(store.archivedTasks[0])
        try await waitForArchived(store, count: 0)
        try await waitForTasks(store, count: 1)
    }
    @Test func deletePermanentlyRemovesArchived() async throws {
        let store = try makeStore()
        try await store.create(completed("a", at: now))
        try await waitForTasks(store, count: 1)
        try await store.archive(store.tasks[0])
        try await waitForArchived(store, count: 1)
        try await store.deletePermanently(store.archivedTasks[0])
        try await waitForArchived(store, count: 0)
        #expect(store.tasks.isEmpty)
    }
    @Test func sweepDisabledArchivesNothing() async throws {
        let store = try makeStore()
        store.archiveSettings = ArchiveSettings(autoEnabled: false, afterDays: 30)
        try await store.create(completed("old", at: day(2026, 1, 1)))   // ancient
        try await waitForTasks(store, count: 1)
        try await store.runAutoArchiveSweep()
        try await _Concurrency.Task.sleep(for: .milliseconds(50))
        #expect(store.tasks.count == 1)            // untouched
        #expect(store.archivedTasks.isEmpty)
    }
    @Test func sweepEnabledArchivesOldCompletedTasks() async throws {
        let store = try makeStore()
        store.archiveSettings = ArchiveSettings(autoEnabled: true, afterDays: 30)
        try await store.create(completed("old", at: day(2026, 1, 1)))   // < cutoff → archive
        try await store.create(completed("recent", at: day(2026, 6, 14)))// recent → keep
        try await waitForTasks(store, count: 2)
        try await store.runAutoArchiveSweep()
        try await waitForArchived(store, count: 1)
        #expect(store.archivedTasks.map(\.id) == ["old"])
        #expect(store.tasks.map(\.id) == ["recent"])
    }
    @Test func archiveSettingsPersistToDefaults() async throws {
        let store = try makeStore()
        store.archiveSettings = ArchiveSettings(autoEnabled: true, afterDays: 60)
        #expect(store.archiveSettings == ArchiveSettings(autoEnabled: true, afterDays: 60))
    }
}
```

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreArchiveTests` → FAIL (archive methods + `archiveSettings` + `runAutoArchiveSweep` not found).

- [ ] **Step 3: Add to `TaskStore.swift`** a `// MARK: Archive` section (after the smart-view section):
```swift
    // MARK: Archive

    /// Move a task into the archive (removed from active). Goes through the archive
    /// repository's single-transaction move; the observers refresh `tasks`/`archivedTasks`.
    /// NOTE (Phase 5): enqueue a sync op here.
    public func archive(_ task: Task) async throws {
        try await archiveRepository.archive(task)
    }

    /// Restore an archived task to active, stamping `updatedAt` so it sorts fresh.
    /// Two writes: the repository re-inserts the stored row, then we upsert the freshened
    /// `updatedAt` (the active observer coalesces both into one snapshot).
    public func restore(_ task: Task) async throws {
        var t = task
        t.updatedAt = clock()
        try await archiveRepository.restore(id: task.id)
        try await repository.upsert(t)
    }

    public func deletePermanently(_ task: Task) async throws {
        try await archiveRepository.deletePermanently(id: task.id)
    }

    /// Archive every completed task older than the configured threshold — but only when
    /// auto-archive is enabled. Pure selection via `AutoArchive`; gating lives here.
    public func runAutoArchiveSweep() async throws {
        let settings = archiveSettings
        guard settings.autoEnabled else { return }
        let toArchive = AutoArchive.tasksToArchive(tasks, afterDays: settings.afterDays,
                                                   now: clock(), calendar: calendar)
        for task in toArchive { try await archiveRepository.archive(task) }
    }

    // MARK: Archive settings (App-Group UserDefaults; design-spec scope call)

    public var archiveSettings: ArchiveSettings {
        get {
            ArchiveSettings(
                autoEnabled: defaults.bool(forKey: AppGroupDefaults.Key.archiveAutoEnabled),
                afterDays: defaults.object(forKey: AppGroupDefaults.Key.archiveAfterDays) as? Int ?? 30
            )
        }
        set {
            defaults.set(newValue.autoEnabled, forKey: AppGroupDefaults.Key.archiveAutoEnabled)
            defaults.set(newValue.afterDays, forKey: AppGroupDefaults.Key.archiveAfterDays)
        }
    }
```
> **`restore` note:** the simplest correct behavior is to restore the stored row, then upsert the freshened `updatedAt`. If you prefer a single write, add a `restore(_ task: Task)` overload to `ArchiveRepository` that takes the freshened task — but the two-step version reuses the repo as-is and is observably correct (the active observer coalesces both writes). Documented.

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreArchiveTests` → PASS (6 tests). Re-run full `cd GSDKit && swift test` → green.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreArchiveTests.swift && git commit -m "feat: add TaskStore archive/restore/delete, auto-sweep, and ArchiveSettings"`

### Task C5: `ArchiveListView` (read-only, swipe Restore/Delete, undo)

**Files:**
- Create: `App/Archive/ArchiveListView.swift`

Read-only dimmed cards of `store.archivedTasks`; leading swipe Restore, trailing swipe Delete (destructive → confirm). `.searchable` (Group D) + `EditMode` bulk (Group E) are added in their tasks; C5 builds the base list. The iPad sidebar already routes `.archive` here (Task A7); the iPhone reaches it via a Browse-list "Archive" row added here.

- [ ] **Step 1:** Write `App/Archive/ArchiveListView.swift`:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// The archive: read-only dimmed task cards. Swipe to Restore (leading) or Delete
/// permanently (trailing, confirmed). Reuses `TaskCardView` at reduced opacity. Search +
/// bulk multi-select are layered on in Groups D/E.
struct ArchiveListView: View {
    @Environment(TaskStore.self) private var store
    @State private var searchText = ""
    @State private var pendingDelete: Task?

    private var results: [Task] {
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return store.archivedTasks }
        return TaskFilter.apply(FilterCriteria(searchQuery: searchText),
                                to: store.archivedTasks, now: .now, calendar: .current)
    }

    var body: some View {
        Group {
            if store.archivedTasks.isEmpty {
                ContentUnavailableView(String(localized: "Archive is empty"),
                                       systemImage: "archivebox",
                                       description: Text(String(localized: "Completed tasks you archive will appear here.")))
            } else {
                List(results) { task in
                    TaskCardView(task: task, now: .now, blockedByCount: 0, blockingCount: 0)
                        .opacity(0.6)
                        .swipeActions(edge: .leading) {
                            Button {
                                _Concurrency.Task { try? await store.restore(task) }
                            } label: { Label(String(localized: "Restore"), systemImage: "arrow.uturn.backward") }
                            .tint(.blue)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingDelete = task } label: {
                                Label(String(localized: "Delete"), systemImage: "trash")
                            }
                        }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle(String(localized: "Archive"))
        .searchable(text: $searchText, prompt: String(localized: "Search archive"))
        .confirmationDialog(String(localized: "Delete permanently?"),
                            isPresented: Binding(get: { pendingDelete != nil },
                                                 set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button(String(localized: "Delete"), role: .destructive) {
                if let task = pendingDelete {
                    _Concurrency.Task { try? await store.deletePermanently(task) }
                }
                pendingDelete = nil
            }
            Button(String(localized: "Cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(String(localized: "This can't be undone."))
        }
    }
}
```
> `.searchable` here satisfies part of A25 (Group D); it's included now because the list is read-only and search is trivial to wire. The bulk-select layer (A27) is added in Group E.

- [ ] **Step 2: Add an "Archive" Browse row (iPhone).** In `App/Browse/SmartViewListView.swift`, add a top section linking to the archive (the `.navigationDestination(for: String.self)` already pushes by id; use a distinct destination). Add inside the `List`, before the Pinned section:
```swift
                Section {
                    NavigationLink {
                        ArchiveListView()
                    } label: {
                        Label(String(localized: "Archive"), systemImage: "archivebox")
                    }
                }
```

- [ ] **Step 3: Build** (new file → `xcodegen generate`) both simulators → exit 0. Launch iPhone: Browse shows an Archive row; archive a completed task (via a swipe added in Group E or by toggling a task complete then using the matrix — for now seed via auto-sweep or a debug archive); the archived task shows dimmed; Restore returns it; Delete confirms then removes. iPad: the sidebar Archive item shows the same. Screenshot.
- [ ] **Step 4: Commit:** `git add App/Archive/ArchiveListView.swift App/Browse/SmartViewListView.swift GSD.xcodeproj && git commit -m "feat: add ArchiveListView with restore/delete + archive entry points"`

### Task C6: Launch auto-archive sweep

**Files:**
- Modify: `App/GSDApp.swift`

- [ ] **Step 1:** Run the sweep once after the store starts. In `GSDApp.body`, extend the `.task`:
```swift
                .task {
                    store.start()
                    try? await store.runAutoArchiveSweep()
                }
```
> The sweep is also re-run when the user changes `archiveSettings` in the archive UI (Group C settings affordance) — wire a `.onChange`/button there if exposing settings inline; for 3b the launch sweep + the settings toggle re-invoking `runAutoArchiveSweep()` is sufficient (A24). A minimal settings affordance (auto toggle + 30/60/90 picker) can live in a toolbar menu on `ArchiveListView`:
```swift
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { archiveSettingsMenu }
        }
```
with
```swift
    @ViewBuilder private var archiveSettingsMenu: some View {
        Menu {
            Toggle(String(localized: "Auto-archive"), isOn: Binding(
                get: { store.archiveSettings.autoEnabled },
                set: { var s = store.archiveSettings; s.autoEnabled = $0; store.archiveSettings = s
                       _Concurrency.Task { try? await store.runAutoArchiveSweep() } }))
            Picker(String(localized: "Archive after"), selection: Binding(
                get: { store.archiveSettings.afterDays },
                set: { var s = store.archiveSettings; s.afterDays = $0; store.archiveSettings = s
                       _Concurrency.Task { try? await store.runAutoArchiveSweep() } })) {
                ForEach(ArchiveSettings.allowedDays, id: \.self) { Text("\($0) days").tag($0) }
            }
        } label: { Label(String(localized: "Archive settings"), systemImage: "gearshape") }
    }
```
Add this menu + toolbar to `ArchiveListView` (Step 1 of C6 covers `GSDApp`; the menu is part of this task — include it in the ArchiveListView edit and rebuild).

- [ ] **Step 2: Build** both simulators → exit 0. Launch: with a completed task older than the threshold + auto on, it is archived on next launch; with auto off, none are. Toggle the setting in the Archive menu and confirm the sweep re-runs.
- [ ] **Step 3: Commit:** `git add App/GSDApp.swift App/Archive/ArchiveListView.swift GSD.xcodeproj && git commit -m "feat: run auto-archive sweep on launch + archive settings menu"`

> **Milestone after Group C:** archive moves a completed task to `archivedTasks` (removed from active); restore returns it; permanent delete removes it; archived tasks are excluded from the matrix/smart views by construction (separate table); auto-archive on launch respects the enabled toggle + threshold with the probe-pinned boundary. `cd GSDKit && swift test` green; both simulators build. **Maps A23, A24.**

---

## Group D — Search + Command palette — App (`xcodebuild`)

### Task D1: `.searchable` on `FilteredTaskListView` (feeds `searchQuery`)

**Files:**
- Modify: `App/Browse/FilteredTaskListView.swift`

The search field overlays the view's own criteria: the active `searchQuery` is ANDed into the view's `FilterCriteria` before filtering. (`ArchiveListView` already got `.searchable` in C5.)

- [ ] **Step 1:** Edit `App/Browse/FilteredTaskListView.swift`. Add a `@State searchText`, fold it into the criteria, and attach `.searchable`. Replace the `tasks` computed property + add the modifier:
```swift
    @State private var searchText = ""

    private var tasks: [Task] {
        var criteria = view.criteria
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { criteria.searchQuery = trimmed }   // overlay search on the view's criteria
        return store.tasks(matching: criteria)
    }
```
and add `.searchable` to the view body (after `.navigationTitle(view.name)`):
```swift
        .searchable(text: $searchText, prompt: String(localized: "Search \(view.name)"))
```
> `searchQuery` matches across title/description/tags/subtask-titles (3a's `TaskFilter`), case-insensitive — A25.

- [ ] **Step 2: Build** both simulators → exit 0. Launch: open a smart view, pull down to reveal search, type a term — the list filters live across title/description/tags/subtasks. Clear it → the view's own criteria resume. Repeat on the Archive list. Screenshot.
- [ ] **Step 3: Commit:** `git add App/Browse/FilteredTaskListView.swift GSD.xcodeproj && git commit -m "feat: add .searchable search overlay to FilteredTaskListView"`

### Task D2: `CommandPaletteView` + ⌘K

**Files:**
- Create: `App/Palette/CommandPaletteView.swift`
- Modify: `App/ContentView.swift`

A single sheet: a search field + sectioned results — **Tasks** (open editor), **Smart Views** (open filtered list), **Actions** (New task, Toggle show-completed, Toggle theme), **Navigation** (Matrix, Browse, Archive). Match = case-insensitive substring. Invoked by ⌘K (hardware keyboard) and a toolbar magnifying-glass. The palette communicates its selection back to `ContentView` via a callback enum, so `ContentView` performs the navigation/editor presentation.

- [ ] **Step 1:** Write `App/Palette/CommandPaletteView.swift`:
```swift
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
enum PaletteDestination { case matrix, browse, archive }

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
         (String(localized: "Browse"), "line.3.horizontal.decrease.circle", .navigate(.browse)),
         (String(localized: "Archive"), "archivebox", .navigate(.archive))]
            .filter { match($0.0) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !taskResults.isEmpty {
                    Section(String(localized: "Tasks")) {
                        ForEach(taskResults) { task in
                            Button { pick(.openTask(task)) } label: {
                                Label(task.title, systemImage: "doc.text")
                            }
                        }
                    }
                }
                if !viewResults.isEmpty {
                    Section(String(localized: "Smart Views")) {
                        ForEach(viewResults) { view in
                            Button { pick(.openSmartView(view.id)) } label: {
                                Label(view.name, systemImage: view.icon)
                            }
                        }
                    }
                }
                if !actionResults.isEmpty {
                    Section(String(localized: "Actions")) {
                        ForEach(actionResults, id: \.0) { label, icon, result in
                            Button { pick(result) } label: { Label(label, systemImage: icon) }
                        }
                    }
                }
                if !navResults.isEmpty {
                    Section(String(localized: "Navigation")) {
                        ForEach(navResults, id: \.0) { label, icon, result in
                            Button { pick(result) } label: { Label(label, systemImage: icon) }
                        }
                    }
                }
            }
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

    private func pick(_ result: PaletteResult) {
        onSelect(result)
        dismiss()
    }
}
```

- [ ] **Step 2: Wire ⌘K + the toolbar button + effect handling into `App/ContentView.swift`.** `ContentView` owns palette presentation, the editor sheet it opens, tab/sidebar selection, and the theme/show-completed toggles. Rewrite `ContentView` to host shared state and a hidden ⌘K button, and pass an `onSelect` handler. Replace `ContentView`:
```swift
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(TaskStore.self) private var store
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue

    @State private var showPalette = false
    @State private var paletteEditor: EditorRequest?
    @State private var compactTab = 0                 // 0 = Matrix, 1 = Browse
    @State private var pushedSmartViewID: String?
    @State private var showArchive = false

    var body: some View {
        rootContent
            // Hidden ⌘K trigger — a zero-size button carrying the keyboard shortcut so the
            // hardware ⌘K opens the palette anywhere in the app (confirm-at-build API).
            .background {
                Button("", action: { showPalette = true })
                    .keyboardShortcut("k", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showPalette = true } label: {
                        Label(String(localized: "Search"), systemImage: "magnifyingglass")
                    }
                }
            }
            .sheet(isPresented: $showPalette) {
                CommandPaletteView(onSelect: handle)
            }
            .sheet(item: $paletteEditor) { TaskEditorView(request: $0) }
            .navigationDestination(isPresented: $showArchive) { ArchiveListView() }
    }

    @ViewBuilder private var rootContent: some View {
        if sizeClass == .compact {
            TabView(selection: $compactTab) {
                MatrixView()
                    .tabItem { Label(String(localized: "Matrix"), systemImage: "square.grid.2x2") }
                    .tag(0)
                SmartViewListView()
                    .tabItem { Label(String(localized: "Browse"), systemImage: "line.3.horizontal.decrease.circle") }
                    .tag(1)
            }
        } else {
            RegularRootView()
        }
    }

    private func handle(_ result: PaletteResult) {
        switch result {
        case .openTask(let task): paletteEditor = .edit(task)
        case .newTask: paletteEditor = .new(.urgentImportant, prefill: nil)
        case .toggleShowCompleted: showCompleted.toggle()
        case .toggleTheme:
            let order = AppTheme.allCases
            let current = AppTheme(rawValue: themeRaw) ?? .system
            let next = order[(order.firstIndex(of: current).map { $0 + 1 } ?? 0) % order.count]
            themeRaw = next.rawValue
        case .navigate(let dest):
            switch dest {
            case .matrix: compactTab = 0
            case .browse: compactTab = 1
            case .archive: showArchive = true
            }
        case .openSmartView(let id):
            compactTab = 1
            pushedSmartViewID = id   // Browse reads this to push (see note)
        }
    }
}
```
> **Build-time notes (confirm at `xcodebuild`):**
> - **`.toolbar` + `.navigationDestination` at the `ContentView` root need a `NavigationStack`/`NavigationSplitView` ancestor.** The compact `TabView` children (`MatrixView`, `SmartViewListView`) each own their own `NavigationStack`, so a top-level `.toolbar` here won't attach. **Resolution:** move the ⌘K hidden-button `.background` + the palette `.sheet` to the root (they don't need a nav bar), and place the magnifying-glass toolbar button INSIDE each surface's existing toolbar (MatrixView, SmartViewListView, ArchiveListView) instead of at `ContentView`. Simplest concrete plan: (a) keep the hidden ⌘K button + palette sheet + editor sheet + archive destination on the root `Group`; (b) add the magnifying-glass button to `MatrixView`'s existing `.toolbar` and `SmartViewListView`'s `.toolbar`, each toggling a shared `showPalette` passed via `@Environment` or a binding. If threading state is awkward, use a lightweight `@Observable PaletteController` in the environment (toggled by the buttons, observed by the root sheet). Flag and pick the cleanest at build; the palette CONTENT (`CommandPaletteView`) is independent of this wiring.
> - **`openSmartView` push:** `pushedSmartViewID` must drive `SmartViewListView`'s `NavigationStack` path. Add a `path: [String]` binding to `SmartViewListView` (or an `.onChange(of: pushedSmartViewID)` that appends to its path). For iPad, set `RegularRootView`'s `selection = .smartView(id)` directly. Wire whichever the build supports; document the chosen mechanism.

- [ ] **Step 3: Build** both simulators → exit 0. Launch iPhone (with a hardware keyboard attached to the sim, or via the toolbar button): ⌘K opens the palette; typing filters Tasks/Smart Views/Actions/Navigation; selecting a Task opens the editor, a Smart View navigates Browse to it, an Action toggles show-completed/theme or opens New task, Navigation switches tabs / opens Archive. Screenshot the palette.
- [ ] **Step 4: Commit:** `git add App/Palette/CommandPaletteView.swift App/ContentView.swift App/Matrix/MatrixView.swift App/Browse/SmartViewListView.swift GSD.xcodeproj && git commit -m "feat: add ⌘K command palette with Tasks/Views/Actions/Navigation"`

> **Milestone after Group D:** `.searchable` filters lists via `searchQuery` (A25); ⌘K opens the palette and all four sections perform their actions (A26). Both simulators build.

---

## Group E — Bulk multi-select — App + `GSDStore`

### Task E1: `TaskStore` bulk mutation methods (logic)

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreBulkTests.swift` (new)

Six bulk ops, each iterating the selected ids, applying per-task, validating, stamping `updatedAt` (via the existing single-task mutation paths where possible so behavior matches). `bulkComplete` toggles each incomplete task to complete (idempotent for already-complete); `bulkMove`/`bulkAddTags`/`bulkRemoveTags`/`bulkSetDue` go through `save` (which validates + stamps); `bulkDelete` deletes each (the repository scrubs dependents). A failed per-task validation does not abort the batch — collect and rethrow nothing for 3b (best-effort), matching the action handlers' `try?` posture; but for testability return the count applied.

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/TaskStoreBulkTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreBulkTests {
    private let now = Date(timeIntervalSince1970: 10_000)
    private func makeStore() throws -> TaskStore {
        let db = try AppDatabase.inMemory()
        return TaskStore(repository: GRDBTaskRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         smartViewRepository: GRDBSmartViewRepository(db),
                         archiveRepository: GRDBArchiveRepository(db, now: { Date(timeIntervalSince1970: 0) }),
                         defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!,
                         clock: { self.now }, newID: { "id" }, calendar: .current)
    }
    private func task(_ id: String, tags: [String] = []) -> Task {
        Task(id: id, title: id, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), tags: tags)
    }
    private func seed(_ store: TaskStore, _ tasks: [Task]) async throws {
        for t in tasks { try await store.create(t) }
        store.start(); var w = 0
        while store.tasks.count != tasks.count && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
    }
    private func reloaded(_ store: TaskStore, _ id: String) async throws -> Task? {
        try await store.tasks.first { $0.id == id }.map { _ in } == nil ? nil : nil
    }

    @Test func bulkCompleteMarksAllComplete() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b"), task("c")])
        try await store.bulkComplete(ids: ["a", "b"])
        var w = 0
        while store.tasks.filter({ $0.completed }).count != 2 && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(Set(store.tasks.filter { $0.completed }.map(\.id)) == ["a", "b"])
    }
    @Test func bulkMoveSetsQuadrant() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b")])
        try await store.bulkMove(ids: ["a", "b"], to: .urgentImportant)
        var w = 0
        while store.tasks.filter({ $0.quadrant == .urgentImportant }).count != 2 && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.allSatisfy { $0.quadrant == .urgentImportant })
    }
    @Test func bulkAddAndRemoveTags() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b", tags: ["keep"])])
        try await store.bulkAddTags(ids: ["a", "b"], tags: ["focus"])
        var w = 0
        while !(store.tasks.first { $0.id == "a" }?.tags.contains("focus") ?? false) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.first { $0.id == "b" }?.tags.sorted() == ["focus", "keep"])
        try await store.bulkRemoveTags(ids: ["a", "b"], tags: ["focus"])
        w = 0
        while (store.tasks.first { $0.id == "a" }?.tags.contains("focus") ?? true) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.first { $0.id == "a" }?.tags.isEmpty == true)
        #expect(store.tasks.first { $0.id == "b" }?.tags == ["keep"])
    }
    @Test func bulkSetDueStampsDueDate() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b")])
        let due = Date(timeIntervalSince1970: 999_999)
        try await store.bulkSetDue(ids: ["a", "b"], to: due)
        var w = 0
        while (store.tasks.first { $0.id == "a" }?.dueDate == nil) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.allSatisfy { $0.dueDate == due })
    }
    @Test func bulkDeleteRemovesTasks() async throws {
        let store = try makeStore()
        try await seed(store, [task("a"), task("b"), task("c")])
        try await store.bulkDelete(ids: ["a", "b"])
        var w = 0
        while store.tasks.count != 1 && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.map(\.id) == ["c"])
    }
    @Test func bulkAddTagsSkipsTaskThatWouldExceedTagLimit() async throws {
        // Validation is per-task: a task already at maxTags is left unchanged, the batch continues.
        let store = try makeStore()
        let full = task("full", tags: (0..<FieldLimits.maxTags).map { "t\($0)" })
        try await seed(store, [full, task("ok")])
        try await store.bulkAddTags(ids: ["full", "ok"], tags: ["new"])
        var w = 0
        while !(store.tasks.first { $0.id == "ok" }?.tags.contains("new") ?? false) && w < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); w += 1 }
        #expect(store.tasks.first { $0.id == "ok" }?.tags.contains("new") == true)
        #expect(store.tasks.first { $0.id == "full" }?.tags.count == FieldLimits.maxTags)  // unchanged
    }
}
```
(Remove the unused `reloaded` helper if the executor's linter flags it — it's illustrative; the assertions read `store.tasks` directly.)

- [ ] **Step 2: Run** `cd GSDKit && swift test --filter TaskStoreBulkTests` → FAIL (bulk methods not found).

- [ ] **Step 3: Add to `TaskStore.swift`** a `// MARK: Bulk operations` section. Each op resolves the selected tasks from the current snapshot, applies, and persists via the existing mutation paths (which validate + stamp). Per-task validation failures are swallowed best-effort (matching `TaskActions`' `try?`), so one bad task never blocks the rest:
```swift
    // MARK: Bulk operations (multi-select; each op is per-task, validated, stamps updatedAt)

    private func selectedTasks(_ ids: Set<String>) -> [Task] {
        tasks.filter { ids.contains($0.id) }
    }

    public func bulkComplete(ids: Set<String>) async throws {
        for task in selectedTasks(ids) where !task.completed {
            try? await toggleComplete(task)   // stamps completedAt/updatedAt + spawns recurrence
        }
    }
    public func bulkMove(ids: Set<String>, to quadrant: Quadrant) async throws {
        for task in selectedTasks(ids) { try? await move(task, to: quadrant) }
    }
    public func bulkAddTags(ids: Set<String>, tags newTags: [String]) async throws {
        for var task in selectedTasks(ids) {
            let merged = task.tags + newTags.filter { !task.tags.contains($0) }
            task.tags = merged
            try? await save(task)             // save validates (tag count/length) + stamps updatedAt
        }
    }
    public func bulkRemoveTags(ids: Set<String>, tags removeTags: [String]) async throws {
        let toRemove = Set(removeTags)
        for var task in selectedTasks(ids) {
            task.tags.removeAll { toRemove.contains($0) }
            try? await save(task)
        }
    }
    public func bulkSetDue(ids: Set<String>, to dueDate: Date?) async throws {
        for var task in selectedTasks(ids) {
            task.dueDate = dueDate
            try? await save(task)
        }
    }
    public func bulkDelete(ids: Set<String>) async throws {
        for task in selectedTasks(ids) { try? await delete(task) }
    }
```
> **Note on `try?` per-task:** swallowing keeps the batch best-effort (a task that would violate a field limit is skipped, the rest apply) — this is what the E1 limit test asserts and matches the app's existing `TaskActions` posture. The methods are `async throws` for signature uniformity (and a future strict mode), but currently never rethrow.

- [ ] **Step 4: Run** `cd GSDKit && swift test --filter TaskStoreBulkTests` → PASS (6 tests). Re-run full `cd GSDKit && swift test` → green.
- [ ] **Step 5: Commit:** `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreBulkTests.swift && git commit -m "feat: add TaskStore bulk operations (complete/move/tags/due/delete)"`

### Task E2: `BulkActionBar` + `EditMode` selection on filtered lists + archive

**Files:**
- Create: `App/Bulk/BulkActionBar.swift`
- Modify: `App/Browse/FilteredTaskListView.swift`
- Modify: `App/Archive/ArchiveListView.swift`

`List(selection:)` + an `EditButton` toggles multi-select; a bottom `.toolbar` `BulkActionBar` exposes the six ops; Delete confirms. On the Archive list, the bar instead offers Restore + Delete (archive has no move/tags/due semantics) — keep `BulkActionBar` focused on active-task ops and give the archive its own slim bar inline.

- [ ] **Step 1:** Write `App/Bulk/BulkActionBar.swift`:
```swift
import SwiftUI
import GSDModel
import GSDStore

/// Bottom action bar shown while multi-selecting active tasks. Six ops; Delete confirms.
/// Move/tags/due open lightweight prompts. Each op calls the store's bulk method then
/// clears the selection.
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
            Button(role: .destructive) { showDeleteConfirm = true } label: {
                Label(String(localized: "Delete"), systemImage: "trash")
            }
        }
        .disabled(selection.isEmpty)
        .padding(.horizontal)
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
        let ids = selection
        _Concurrency.Task { @MainActor in
            try? await op()
            selection.removeAll()
        }
        _ = ids
    }
}
```

- [ ] **Step 2: Add selection + EditButton + the bar to `FilteredTaskListView`.** Add `@State private var selection = Set<String>()`, switch the `List` to `List(selection:)`, add an `EditButton`, and attach the bar in a bottom bar that appears in edit mode. Replace the `List(tasks)` block + toolbar:
```swift
                    List(selection: $selection) {
                        ForEach(tasks) { task in
                            TaskListRow(
                                task: task,
                                blockedByCount: graph.uncompletedBlockers(of: task.id).count,
                                blockingCount: graph.blockedTasks(of: task.id).count,
                                actions: rowActions,
                                onEdit: { editor = .edit($0) }
                            )
                            .tag(task.id)
                        }
                    }
                    .listStyle(.insetGrouped)
```
and add to the view body:
```swift
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if !selection.isEmpty { BulkActionBar(selection: $selection) }
            }
        }
```
> `List(selection:)` shows checkboxes only in `.active` edit mode (driven by `EditButton`). `.tag(task.id)` makes the selection a `Set<String>` of ids. **Confirm at build:** if the bottom bar doesn't appear, gate it on the environment `editMode?.wrappedValue.isEditing` instead of `!selection.isEmpty`. Flag at build.

- [ ] **Step 3: Add a slim bulk Restore/Delete bar to `ArchiveListView`** using the same `List(selection:)`+`EditButton` pattern, but with archive-specific ops (no move/tags/due):
```swift
        // inside ArchiveListView: @State private var selection = Set<String>()
        // wrap List as List(selection: $selection) { ForEach(results) { ... .tag($0.id) } }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                if !selection.isEmpty {
                    Button(String(localized: "Restore")) {
                        let ids = selection
                        _Concurrency.Task { for t in store.archivedTasks where ids.contains(t.id) { try? await store.restore(t) }; selection.removeAll() }
                    }
                    Spacer()
                    Button(String(localized: "Delete"), role: .destructive) {
                        let ids = selection
                        _Concurrency.Task { for t in store.archivedTasks where ids.contains(t.id) { try? await store.deletePermanently(t) }; selection.removeAll() }
                    }
                }
            }
        }
```
(Keep the existing single-swipe Restore/Delete + the settings menu; this adds the multi-select layer alongside.)

- [ ] **Step 4: Build** (new file → `xcodegen generate`) both simulators → exit 0. Launch: in a filtered list tap Edit, select rows, the bottom bar appears; Complete marks them done; the Edit menu moves quadrant / adds / removes tags / sets due; Delete confirms then removes. In the Archive, Edit → select → Restore / Delete (confirmed). Screenshot a selection state.
- [ ] **Step 5: Commit:** `git add App/Bulk/BulkActionBar.swift App/Browse/FilteredTaskListView.swift App/Archive/ArchiveListView.swift GSD.xcodeproj && git commit -m "feat: add bulk multi-select with BulkActionBar on lists and archive"`

> **Milestone after Group E:** multi-select on filtered lists + archive; each of the six bulk ops applies per-task (validated, `updatedAt` stamped) via the store; delete confirms. `cd GSDKit && swift test` green; both simulators build. **Maps A27.**

---

## Phase 3b — Definition of Done

Mapped to the spec's acceptance criteria (A20–A27).

- [ ] **A20 — Custom smart views.** Create/edit/delete persist (GRDB `smartViews` via `registerV2` + `SmartViewRecord` + `SmartViewRepository`), survive relaunch; the 9 built-ins are read-only (no Edit/Delete affordance). *Tests:* `SmartViewRecordTests`, `SmartViewRepositoryTests`, `TaskStoreSmartViewTests` (create/update/delete). *Tasks:* A1–A4, A6, A7, B1. *Build:* both simulators.
- [ ] **A21 — Pinning.** Pin up to 5 (ordered), surface first in Browse + sidebar; persists in App-Group UserDefaults. *Tests:* `SmartViewPinningTests` (cap/dupe/unpin/reorder), `TaskStoreSmartViewTests` (`allViewsOrdersPinnedThenBuiltInsThenCustom`, `pinPersistsToDefaultsAndCapsAtFive`, delete-unpins). *Tasks:* A5, A6, A7.
- [ ] **A22 — Criteria editor.** Every editable §5.9 field (quadrants, status, tags, overdue/dueToday/dueThisWeek/noDueDate, dueDateRange, recurrence, readyToWork, searchQuery) round-trips through Save; the saved view's results match `TaskFilter` (the same pure engine that powers counts). Two halves: (i) field round-trip — verified by edit-reopen in B1's build step + `FilterCriteriaCodableTests` (the persistence layer); (ii) results match `TaskFilter` — the editor stores raw `FilterCriteria` consumed by `store.tasks(matching:)`. *Tasks:* A1 (Codable), B1. *Build:* both simulators.
- [ ] **A23 — Archive.** Archive moves a completed task to `archivedTasks` (removed from active, one transaction); restore returns it; permanent delete removes it; archived tasks are excluded from the matrix/smart views by construction (separate table — active queries never read `archivedTasks`). *Tests:* `ArchiveRepositoryTests` (move/restore/delete/isolation/observe), `TaskStoreArchiveTests` (round-trip/delete). *Tasks:* C1b–C3, C4, C5. *Build:* both simulators.
- [ ] **A24 — Auto-archive.** With auto on + `archiveAfterDays` N, completed tasks older than N days archive on the launch sweep; off → none; boundary correct (`completedAt < startOfDay(now) − N`, exclusive). *Tests:* `AutoArchiveTests` (8 boundary cases — **probe-pinned**), `TaskStoreArchiveTests` (`sweepDisabledArchivesNothing`, `sweepEnabledArchivesOldCompletedTasks`). *Tasks:* C1a, C4, C6.
- [ ] **A25 — Search.** `.searchable` filters lists via `searchQuery` across title/description/tags/subtask-titles (case-insensitive, 3a `TaskFilter`). *Surfaces:* `FilteredTaskListView` (D1) + `ArchiveListView` (C5). *Build:* both simulators.
- [ ] **A26 — Command palette.** ⌘K (hardware keyboard) + a toolbar magnifying-glass open the palette; Tasks (open editor), Smart Views (open filtered list), Actions (New task / Toggle show-completed / Toggle theme), Navigation (Matrix / Browse / Archive) all work. *Tasks:* D2. *Build:* both simulators (confirm ⌘K with a sim hardware keyboard).
- [ ] **A27 — Bulk.** Multi-select (`EditMode` + `List(selection:)`) on filtered lists + archive; each of the 6 ops (Complete, Move, Add tags, Remove tags, Set due, Delete→confirm) applies per-task (validated, `updatedAt` stamped) via the store; delete confirms. *Tests:* `TaskStoreBulkTests` (6 ops + per-task validation skip). *Tasks:* E1, E2. *Build:* both simulators.
- [ ] **Coverage.** `cd GSDKit && swift test` fully green, sub-second for all new logic (FilterCriteria Codable, AutoArchive, the three repos, pinning, store CRUD/archive/bulk, v2/v3 migrations fresh + existing); both simulators build + launch (smoke screenshots: Browse pinned/custom, criteria editor, Archive, palette, a bulk-select state). One commit per task.

---

## Self-review (spec coverage · placeholders · type consistency)

**Spec coverage (design-spec §3–§6):**
- §3 scope calls — smartViews GRDB v2 (A2–A4) ✔; pinning + ArchiveSettings in App-Group UserDefaults, NOT GRDB (A5, A6, C4) ✔; archivedTasks GRDB v3 (C1b–C3) ✔; pure `AutoArchive` in `GSDModel` (C1a) ✔; criteria editor exposes every editable field (B1) ✔; ⌘K palette four sections (D2) ✔; `.searchable` (C5, D1) ✔; bulk multi-select 6 ops (E1, E2) ✔; sync deferral as documented TODO (C4 `archive` comment) ✔.
- §4 groups A–E — all present, mapped to tasks A1–A7 / B1 / C1a–C6 / D1–D2 / E1–E2 ✔.
- §5 testing — FilterCriteria Codable (A1), AutoArchive boundary/completed-only/disabled (C1a + C4), SmartView repo CRUD+observe (A4), Archive archive/restore/delete + isolation (C3), pinning persistence (A5/A6), bulk store methods + validation (E1), migrations v2/v3 fresh + existing (A3, C2) ✔.
- §6 A20–A27 — all mapped in the Definition of Done above (A22 split into its two halves; A24 tied to the boundary probe) ✔.

**Placeholder scan:** every code step contains complete, compilable Swift — no `TBD`/`...`/"similar to". The cross-group dependency (A6 needs `GRDBArchiveRepository`) is resolved by an explicit execution-order directive, not a placeholder. Two UI-wiring decisions are flagged as **confirm-at-build** with a concrete primary plan + a named fallback (the ⌘K toolbar-placement note in D2; the `EditMode` bottom-bar visibility gate in E2); these are genuine SwiftUI "can't /tmp-probe" calls per convention #10, not unfinished code. The `ArchivedTaskRecord.toDomain()` memberwise-init assumption (C1b) is flagged confirm-at-build with a fallback (inline the field mapping).

**Type consistency across tasks:**
- `FilterCriteria` gains `Codable` + `Status: String, …, CaseIterable` (A1) — consumed by `SmartViewRecord` JSON (A2), the editor's segmented `Status` Picker (B1), and `AutoArchive` is independent of it.
- `SmartViewRecord(_:createdAt:updatedAt:)` / `.toDomain()` (A2) ↔ `SmartViewRepository.upsert(_:createdAt:updatedAt:)` (A4) ↔ `TaskStore.createView`/`updateView` (A6) — signatures aligned.
- `ArchivedTaskRecord(_:archivedAt:)` / `.toDomain()` (C1b) ↔ `ArchiveRepository.archive/restore/deletePermanently/fetchAll/observeAll` (C3) ↔ `TaskStore.archive/restore/deletePermanently/runAutoArchiveSweep` (C4) — aligned; `restore` is two-step (repo restore + `updatedAt` upsert), documented.
- `TaskStore.init(repository:smartViewRepository:archiveRepository:defaults:clock:newID:calendar:)` (A6) — every test `makeStore` + `GSDApp` (A7) construct it with this exact signature; existing GSDStore tests are updated in A6 Step 6.
- `AppGroupDefaults.Key.{pinnedSmartViewIds,archiveAutoEnabled,archiveAfterDays}` + `ArchiveSettings(autoEnabled:afterDays:)` (A5) — used by pinning (A6) + archive settings (C4) consistently.
- `SmartViewPinning.{pin,unpin,reorder,maxPins}` (A5) ↔ `TaskStore.{pin,unpin,reorderPins,pinnedSmartViewIds}` (A6).
- `SmartViewEditorTarget` (`.create`/`.edit`) + `SmartViewEditorView(target:)` (B1) ↔ referenced by `SmartViewListView` + `RegularRootView` (A7).
- `PaletteResult`/`PaletteDestination` + `CommandPaletteView(onSelect:)` (D2) ↔ `ContentView.handle(_:)` (D2).
- `BulkActionBar(selection:)` + `TaskStore.bulk{Complete,Move,AddTags,RemoveTags,SetDue,Delete}` (E1) ↔ `BulkActionBar` + `FilteredTaskListView`/`ArchiveListView` selection (E2).
- App refs match real Phase-0/3a APIs: `TaskCardView(task:now:blockedByCount:blockingCount:)`, `TaskActions(store:onCompleted:)`, `EditorRequest.edit/.new`, `ConfettiView(trigger:)`, `QuadrantStyle.accent/.symbol`, `Quadrant.allCases/.title`, `FieldLimits.{maxTags,tagLengthRange}`, `String(localized:)`, `_Concurrency.Task`, `UserDefaults.shared`/`AppTheme` (App layer).

**Convention compliance:** `GSDModel` additions (`FilterCriteria: Codable`, `AutoArchive`) link only Foundation ✔. `GSDStore` additions import GRDB, never SwiftUI (`SmartViewPinning.reorder` reimplements `Array.move` with Foundation `IndexSet`) ✔. Time injected everywhere (AutoArchive, archive `now`, store `clock`) ✔. `_Concurrency.Task` in every app/test concurrency site ✔. `String(localized:)` on all UI copy ✔. Store stamps `updatedAt` on primary mutations; repos stamp only originated rows (none here cascade) ✔. New `.swift` files trigger `xcodegen generate` before `xcodebuild` ✔. One commit per task ✔. No `DEVELOPMENT_TEAM` line added to `GSD.xcodeproj` ✔.

**Probes (folded in):** FilterCriteria Codable round-trip through GSDJSON's exact ms-truncating ISO-8601 strategy — 3/3 PASS (defaults, fully-populated incl. nested DateRange + arrays, open-ended range); `Status` encodes as `"active"` (note after A1). AutoArchive boundary — 8/8 PASS, rule pinned: `completedAt < startOfDay(now) − N days` (exclusive `<`, anchor = startOfDay) (note after C1a). SwiftUI APIs (`.searchable`, ⌘K `.keyboardShortcut`, `List(selection:)`+`EditMode`+bottom `.toolbar`) are confirm-at-build per convention #10 — not probed.
