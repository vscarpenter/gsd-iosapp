# Phase 5a — Sync Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure, backend-free core of PocketBase sync — a new `GSDSync` package target holding the §7.1 wire DTO, lenient wire-date handling, the bidirectional `Task`↔record mapper, and last-write-wins comparison; plus the persisted sync queue (`SyncQueueItem` + a v4 GRDB table + repository, left *unwired*) and device identity in `GSDStore`. All deterministic, `swift test`-verified, no live backend.

**Architecture:** A third library product `GSDSync` (depends on `GSDModel` only in 5a; GRDB-free, networking-free) is the permanent home for all sync logic — transport arrives in 5b/5c. The wire DTO keeps date fields as raw `String`s so leniency lives in exactly one place (`WireDate`, the lenient counterpart to the strict `GSDJSON`). The mapper is three pure functions (`toWire` / `toDomain(mergingInto:)` / merge), taking `owner`/`deviceId`/`recordId` as parameters so it never does I/O. The persisted queue lives in `GSDStore` (it's GRDB-backed local state, like the archive/smart-view tables) because `GSDSync` may depend on `GSDStore` but never the reverse; the queue is built + tested here but wired to `TaskStore` mutations only in 5c (the clean 5a/5c seam).

**Tech Stack:** Swift 6 (toolchain Apple Swift 6.x, Xcode 26.x), `Foundation` only in `GSDSync` (`ISO8601DateFormatter`, `Codable`), GRDB 7 in `GSDStore`, Swift Testing (`@Test`/`#expect`/`#require`) for logic, `xcodebuild` + simctl for the unchanged-app regression smoke, `xcodegen generate` after the `Package.swift` change.

**Builds on (Phases 0–4, committed on `main` at `phase-4-notifications`):**
- `GSDModel` (zero-dep, Foundation only): `Task` (full §5.1 field set; `id`/`title`/`description`/`urgent`/`important`/`completed`/`completedAt`/`createdAt`/`updatedAt`/`dueDate`/`recurrence: RecurrenceType`/`tags: [String]`/`subtasks: [Subtask]`/`dependencies: [String]`/`parentTaskId`/`notifyBefore: Int?`/`notificationEnabled`/`notificationSent`/`lastNotificationAt`/`snoozedUntil`/`estimatedMinutes: Int?`/`timeSpent: Int?`/`timeEntries: [TimeEntry]`; computed `quadrant: Quadrant { Quadrant(urgent:important:) }`; `Codable`/`Sendable`/`Equatable`; custom lenient `init(from:)` + explicit `CodingKeys`), `Subtask {id,title,completed}` (exactly the §7.1 subtask shape — reused directly), `TimeEntry {id, startedAt, endedAt: Date?, notes: String?}`, `RecurrenceType` (`.none`/`.daily`/`.weekly`/`.monthly`, `RawRepresentable` String), `Quadrant` (`rawValue` String), `IDGenerator`.
- `GSDStore` (GRDB, no SwiftUI): `AppDatabase` (`writer: any DatabaseWriter`; `Self.migrator.migrate(writer)` on init; `inMemory()` for tests, `live()` on-disk), `AppDatabase.migrator` (registers v1→v3, returns the `DatabaseMigrator`), the `TaskRecord`/`GSDJSON` mapper pattern (scalars direct, embedded collections as JSON strings via `GSDJSON`; `GSDJSON` is the **strict** ms-ISO-8601 codec), `TaskRepository`/`GRDBTaskRepository` (protocol `Sendable`, final class with `dbWriter: any DatabaseWriter` + injected `now`; `upsert`/`fetchAll`/`fetch(id:)`/`delete(id:)`/`replaceAll`/`observeAll`), `AppGroupDefaults` (`nonisolated(unsafe) static let shared: UserDefaults`, `Key` namespace, falls back to `.standard`), `StoreLocation.appGroupID = "group.dev.vinny.gsd"`.
- Package: `GSDKit/Package.swift` (`swift-tools-version: 6.2`, products `GSDModel` + `GSDStore`, GRDB dependency, testTargets `GSDModelTests`/`GSDStoreTests`).

**Reference:** design spec `docs/specs/2026-05-30-phase-5a-sync-foundation.md` (Groups A–C, A42–A48); product spec `2026-05-30-native-ios-app-design.md` §7 (Sync & Backend wire schema/mapper/LWW/queue/device-identity) + §8.4 (identity, resolved (c) email-keyed — a 5b concern); exemplars `docs/superpowers/plans/2026-05-30-phase-3a-…`, `…-3b-…`, `…-3c-…`, `…-4-notifications.md`.

---

## Architecture conventions locked by this plan (read first)

1. **`GSDSync` is `Foundation`-only in 5a.** NO GRDB, NO networking (`URLSession`/`ASWebAuthenticationSession`), NO SwiftUI, NO `import GSDStore`. It depends on `GSDModel` only. (`GSDSync` gains `GSDStore` in 5c when the engine needs the repositories — not now.)
2. **`GSDModel` stays untouched and zero-dep.** No wire/PocketBase concepts leak into the domain core. The wire DTO reuses `GSDModel.Subtask` (it already matches `{id,title,completed}`) but defines its own `WireTimeEntry` (the local `TimeEntry` carries `endedAt`/`notes` the wire form drops).
3. **Date leniency lives in ONE place — `WireDate` — never `GSDJSON`.** The DTO keeps every date as a raw `String`; the mapper converts via `WireDate`. **PROBE-VERIFIED (26/26):** `parse` tries `[.withInternetDateTime, .withFractionalSeconds]` then falls back to `[.withInternetDateTime]` (whole-second), maps `""`→nil and unparseable→nil; `format` emits canonical fractional-seconds and nil→`""`. Do NOT reuse the strict `GSDJSON` (it rejects whole-second + would throw on `""`).
4. **Absent values differ by type in §7.1 — the DTO decode is defensive. PROBE-VERIFIED (26/26):** date fields are empty-string when absent (`due_date: ""`), `notify_before`/`estimated_minutes` are JSON `null` when absent; a custom `init(from:)` uses `decodeIfPresent(...) ?? default` for every field so empty-string, JSON-null, AND key-absent all decode without throwing. Only `task_id` is `decode` (required — a record without the join key is malformed → skipped). This mirrors the `Task.init(from:)` lenient-decode precedent.
5. **The mapper is pure — `owner`/`deviceId`/`recordId` are parameters.** `toWire(_ task:, owner:, deviceId:, recordId:)` never fetches identity or does I/O. The 5c push engine supplies them. This keeps every mapper test a value-in/value-out fixture with no backend and no device.
6. **Quadrant is recomputed, never trusted from the wire.** On `toDomain`, the resulting `Task.quadrant` derives from `urgent`/`important` (it's a computed property) — the wire `quadrant` string is informational and ignored. `toWire` emits `task.quadrant.rawValue`.
7. **The merge preserve-local set (pull-merge into an existing local `Task`):** `notificationSent`, `lastNotificationAt`, `snoozedUntil` (device-local, §7.4/§9.3); `timeEntries` (wire form lossy — no `endedAt`/`notes`, §7.2 prefers local); **`timeSpent`** (derived from `timeEntries` per `Task.swift` — it MUST follow the kept entries, so it stays local too, never taken from remote independently); **`parentTaskId`** (§7.1 has no wire column — device-local: preserve-on-pull, omit-on-push). Everything else comes from remote. The reconstruct path (no local task) takes all of these from the wire/synthesis.
8. **LWW compares millisecond integers. PROBE-VERIFIED (26/26):** `Int(date.timeIntervalSince1970 * 1000)` (matches the web app). `resolve(localUpdatedAt: Date?, remoteClientUpdatedAt: Date?)` → remote-ms > local-ms `.takeRemote`; local-ms > remote-ms `.keepLocal`; equal-ms `.noOp`; nil remote `.noOp`; nil local (no local task) `.takeRemote`. Sub-millisecond differences that land in the same ms bucket → `.noOp`.
9. **timeEntries flatten/reconstruct. PROBE-VERIFIED (26/26):** flatten each `{id,startedAt,endedAt,notes}` → `{id,startedAt,minutes}` with `minutes = floor((endedAt − startedAt)/60)`; a running entry (nil `endedAt`) → `minutes = 0`. Reconstruct (new-from-remote only) → `endedAt = startedAt + minutes·60`, `notes = nil`. The round-trip is lossy (sub-minute precision + `notes`) — tests ASSERT that loss rather than pretend round-trip is exact.
10. **The persisted queue lives in `GSDStore`, not `GSDSync`.** `SyncQueueItem` (value type), `SyncQueueRecord` (GRDB), `registerV4`, and `SyncQueueRepository` are all in `GSDStore`. `GSDSync` (5c) will read the queue via the repository — `GSDStore` can never depend up on `GSDSync`. The queue is **built + tested but NOT wired to `TaskStore` mutations** in 5a (that hook is 5c). Adding the enqueue-on-mutation now would be a half-built push with no engine to drain it.
11. **`GSDModel.Task` shadows Swift Concurrency's `Task`.** In `GSDSync`/tests, the domain type is bare `Task`; for any concurrency use `_Concurrency.Task { }` (none needed in 5a's pure code, but the convention holds).
12. **Inject time and the defaults suite.** `DeviceIdentity` takes an injectable `UserDefaults` suite + a `nameProvider: () -> String` so the package stays UIKit-free and the logic is deterministic in tests. Mapper/LWW tests pin a fixed UTC gregorian calendar + fixed dates.
13. **Fixtures load via `Bundle.module`.** The `GSDSyncTests` target declares `resources: [.copy("Fixtures")]` — **PROBE-VERIFIED:** `.copy` preserves the directory so `Bundle.module.url(forResource:withExtension:subdirectory: "Fixtures")` resolves (to `…/GSDSync_GSDSyncTests.bundle/Fixtures/<name>.json`); `.process` may flatten the directory and break the `subdirectory:` lookup (a confusing "resource not found" nil). Fixtures are spec-authored JSON. **5b TODO** (a `// NOTE (5b)` in the fixture-loader test): reconcile these against real `api.vinny.io` responses once reachable — a green test here proves mapper self-consistency, NOT wire-format fidelity.
14. **The app is unchanged in 5a.** Nothing in `App/` consumes `GSDSync` yet (its `project.yml` dependency is deferred to 5c). The simctl smoke is a pure regression check (build + launch + screenshot, both sims).

---

## Scope calls (from the approved spec §3; do not relitigate)

- **New `GSDSync` target** depends on `GSDModel` only; `GSDStore` dep deferred to 5c; app `project.yml` dep deferred to 5c.
- **`PocketBaseTaskRecord`** = faithful §7.1 DTO, snake_case `CodingKeys`, typed JSON arrays (`tags: [String]`, `subtasks: [Subtask]`, `dependencies: [String]`, `time_entries: [WireTimeEntry]`), dates as raw `String`, carries record `id`/`task_id`/`owner`/`device_id`, omits system `created`/`updated`.
- **`WireDate`** lenient (probe convention 3). **`TaskWireMapper`** pure (conventions 5–7, 9). **`LWW`** ms-int (convention 8).
- **`SyncQueueItem`** (§7.5): `id`, `taskId`, `operation` (`.create`/`.update`/`.delete`), `timestamp: Int` (ms), `retryCount: Int`, `payload: Task?`, `status` (`.pending`/`.failed`), `lastError: String?`, `lastAttemptAt: Int?`, `failedAt: Int?`. **`SyncQueueRepository`**: `enqueue`/`pending()` (ordered by `timestamp`)/`update`/`remove`. **Unwired** (convention 10).
- **`DeviceIdentity`** (§7.8): stable `deviceId` (UUID, persisted) + `deviceName`, App-Group `UserDefaults` (new `AppGroupDefaults.Key.deviceId`/`.deviceName`), injectable suite + name provider.
- **`parentTaskId`** device-local (preserve-on-pull/omit-on-push) — recurrence lineage does not propagate cross-device (accepted).

---

## Probe Results (run before this plan shipped; folded in)

One standalone Swift probe ran against the installed toolchain in `/tmp/p5a-probe/probe.swift` — **26/26 PASS**:
- **`WireDate` (7):** fractional parse; whole-second parse (the strict-`GSDJSON` gap); `+00:00` offset parse; `""`→nil; garbage→nil; `format(nil)`→`""`; fractional format round-trip (<0.5 ms drift).
- **Defensive decode (9):** snake_case `task_id`→`taskId`; `due_date: ""`→`""`→nil Date; `notify_before: null`→nil; `estimated_minutes` present decodes; key-absent optionals→nil; present `due_date` parses; key-absent non-optional `due_date`→defaulted `""`; missing required `task_id`→decode fails (record skipped); `msSinceEpoch(1.5s)==1500`.
- **LWW (6):** remote newer→takeRemote; local newer→keepLocal; equal-ms→noOp; nil remote→noOp; nil local→takeRemote; sub-ms-same-bucket→noOp.
- **timeEntries (3):** `floor(95s)`→1 min; reconstruct `endedAt = startedAt + minutes·60`; running→minutes 0→`endedAt==startedAt`.

The actual `Package.swift` target wiring + `Bundle.module` resource loading + GRDB v4 migration are **confirm-at-build** (`swift build`/`swift test` in Groups A–C), not `/tmp`-probeable.

---

## File Structure

```
GSDKit/
├─ Package.swift                              # MODIFIED (A): + GSDSync target/product + GSDSyncTests testTarget (Fixtures resource)
├─ Sources/GSDSync/                           # NEW MODULE (A)
│  ├─ PocketBaseTaskRecord.swift              # §7.1 wire DTO (+ WireTimeEntry) — defensive Codable, snake_case
│  ├─ WireDate.swift                          # lenient ISO-8601 parse/format (probe convention 3)
│  ├─ TaskWireMapper.swift                    # toWire / toDomain(mergingInto:) (conventions 5–7, 9)
│  └─ LWW.swift                               # ms-int last-write-wins (convention 8)
├─ Tests/GSDSyncTests/
│  ├─ WireDateTests.swift                     # (A) parse/format leniency
│  ├─ PocketBaseTaskRecordTests.swift         # (A) defensive decode: empty/null/absent + fixtures + skip-malformed
│  ├─ TaskWireMapperTests.swift               # (A) toWire/toDomain/merge + round-trip documented loss + id↔task_id
│  ├─ LWWTests.swift                          # (A) four outcomes at ms granularity
│  └─ Fixtures/                               # (A) spec-authored PocketBase JSON
│     ├─ task_well_formed.json
│     ├─ task_empty_dates.json
│     ├─ task_missing_fields.json
│     └─ task_malformed.json
├─ Sources/GSDStore/
│  ├─ SyncQueueItem.swift                     # NEW (B): §7.5 value type (operation/status enums)
│  ├─ SyncQueueRecord.swift                   # NEW (B): GRDB row + Task-payload JSON via GSDJSON
│  ├─ SyncQueueRepository.swift               # NEW (B): protocol + GRDB impl (enqueue/pending/update/remove)
│  ├─ Migrations.swift                        # MODIFIED (B): + registerV4 (syncQueue table) + register in migrator
│  ├─ DeviceIdentity.swift                    # NEW (C): deviceId(UUID)+deviceName, App-Group, injectable
│  └─ AppGroupDefaults.swift                  # MODIFIED (C): + Key.deviceId / Key.deviceName
└─ Tests/GSDStoreTests/
   ├─ SyncQueueRepositoryTests.swift          # NEW (B): v4 migration coexist + enqueue/pending(ordered)/update/remove + nil-payload delete
   └─ DeviceIdentityTests.swift               # NEW (C): stable id across calls, injected suite + name provider
```

**Sequencing:** A (the `GSDSync` module + pure transforms) is independent and lands first — it's the riskiest/most-probed surface and needs only the package change. B (queue persistence) and C (device identity) are independent `GSDStore` additions and can land in either order after A (no dependency between B and C; neither depends on A). Each task is red→green→commit. Run package tests from `GSDKit/`: `swift test --filter <SuiteName>`.

---

## Group A — `GSDSync` module + pure transforms (`swift test`, sub-second)

> The new target is `Foundation`-only (convention 1). Build fully red→green; nothing in the app consumes it yet. Run from the package root: `cd GSDKit && swift test --filter GSDSyncTests`. Maps **A42–A46**. PROBE-VERIFIED (26/26).

### Task A1: Scaffold the `GSDSync` target + `WireDate`

**Files:**
- Modify: `GSDKit/Package.swift`
- Create: `GSDKit/Sources/GSDSync/WireDate.swift`
- Test: `GSDKit/Tests/GSDSyncTests/WireDateTests.swift`

- [ ] **Step 1: Add the `GSDSync` target/product + `GSDSyncTests` test target to `Package.swift`**

Add the product, target, and test target (NO `resources:` line yet — the `Fixtures` folder doesn't exist until Task A2, and a missing resource path is a build error):

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSDKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GSDModel", targets: ["GSDModel"]),
        .library(name: "GSDStore", targets: ["GSDStore"]),
        .library(name: "GSDSync", targets: ["GSDSync"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(name: "GSDModel"),
        .target(
            name: "GSDStore",
            dependencies: [
                "GSDModel",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(name: "GSDSync", dependencies: ["GSDModel"]),
        .testTarget(name: "GSDModelTests", dependencies: ["GSDModel"]),
        .testTarget(name: "GSDStoreTests", dependencies: ["GSDStore"]),
        .testTarget(name: "GSDSyncTests", dependencies: ["GSDSync"]),
    ]
)
```

- [ ] **Step 2: Create a minimal `WireDate` stub so the new target compiles**

`GSDKit/Sources/GSDSync/WireDate.swift`:

```swift
import Foundation

enum WireDate {
    static func parse(_ string: String) -> Date? { nil }
    static func format(_ date: Date?) -> String { "" }
}
```

- [ ] **Step 3: Write the failing test** — `GSDKit/Tests/GSDSyncTests/WireDateTests.swift`:

```swift
import Testing
import Foundation
@testable import GSDSync

struct WireDateTests {
    @Test func parsesFractionalSeconds() {
        #expect(WireDate.parse("2026-06-15T09:00:00.500Z") != nil)
    }

    @Test func parsesWholeSeconds() {
        // The strict GSDJSON rejects this form; WireDate must accept it.
        #expect(WireDate.parse("2026-06-15T09:00:00Z") != nil)
    }

    @Test func parsesNumericOffset() {
        #expect(WireDate.parse("2026-06-15T09:00:00+00:00") != nil)
    }

    @Test func emptyStringIsNil() {
        #expect(WireDate.parse("") == nil)
    }

    @Test func garbageIsNil() {
        #expect(WireDate.parse("not-a-date") == nil)
    }

    @Test func formatNilIsEmptyString() {
        #expect(WireDate.format(nil) == "")
    }

    @Test func fractionalRoundTrips() throws {
        let original = try #require(WireDate.parse("2026-06-15T09:00:00.500Z"))
        let restored = try #require(WireDate.parse(WireDate.format(original)))
        #expect(abs(restored.timeIntervalSince1970 - original.timeIntervalSince1970) < 0.0005)
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd GSDKit && swift test --filter WireDateTests`
Expected: FAIL — `parsesFractionalSeconds`/`parsesWholeSeconds`/etc. fail because the stub returns `nil`/`""`.

- [ ] **Step 5: Implement `WireDate`** — replace the stub in `GSDKit/Sources/GSDSync/WireDate.swift`:

```swift
import Foundation

/// Lenient ISO-8601 handling for the PocketBase wire boundary — the lenient counterpart to
/// GSDStore's strict `GSDJSON`. PocketBase/web may emit dates with or without fractional
/// seconds, and §7.1 uses the empty string for an absent date. Parsing tolerates both forms
/// and maps empty/unparseable to nil; formatting emits the canonical fractional-seconds form.
/// A fresh `ISO8601DateFormatter` is created per call (it is not `Sendable`).
enum WireDate {
    private static func fractional() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    private static func wholeSecond() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }

    /// Empty → nil; fractional-seconds → Date; whole-second → Date; otherwise nil.
    static func parse(_ string: String) -> Date? {
        if string.isEmpty { return nil }
        if let date = fractional().date(from: string) { return date }
        return wholeSecond().date(from: string)
    }

    /// nil → "" (the §7.1 absent-date form); otherwise canonical fractional-seconds.
    static func format(_ date: Date?) -> String {
        guard let date else { return "" }
        return fractional().string(from: date)
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd GSDKit && swift test --filter WireDateTests`
Expected: PASS (7 tests).

- [ ] **Step 7: Commit**

```bash
git add GSDKit/Package.swift GSDKit/Sources/GSDSync/WireDate.swift GSDKit/Tests/GSDSyncTests/WireDateTests.swift
git commit -m "feat(sync): add GSDSync target + lenient WireDate (A42/A43)"
```

---

### Task A2: `PocketBaseTaskRecord` (defensive decode) + fixtures + skip-malformed

**Files:**
- Create: `GSDKit/Sources/GSDSync/PocketBaseTaskRecord.swift`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/task_well_formed.json`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/task_empty_dates.json`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/task_missing_fields.json`
- Create: `GSDKit/Tests/GSDSyncTests/Fixtures/task_list_with_malformed.json`
- Modify: `GSDKit/Package.swift` (add the `Fixtures` resource to `GSDSyncTests`)
- Test: `GSDKit/Tests/GSDSyncTests/PocketBaseTaskRecordTests.swift`

- [ ] **Step 1: Create the four fixtures** (spec-authored §7.1 JSON; `// NOTE (5b)`: reconcile against real `api.vinny.io` responses once reachable)

`GSDKit/Tests/GSDSyncTests/Fixtures/task_well_formed.json`:

```json
{
  "id": "rec_abc123",
  "task_id": "task-1",
  "owner": "user-1",
  "title": "Ship sync",
  "description": "the whole thing",
  "urgent": true,
  "important": true,
  "quadrant": "do",
  "due_date": "2026-06-15T09:00:00.000Z",
  "completed": false,
  "completed_at": "",
  "recurrence": "weekly",
  "tags": ["work", "sync"],
  "subtasks": [{"id": "sub1", "title": "design", "completed": true}],
  "dependencies": ["task-0"],
  "notification_enabled": true,
  "notification_sent": false,
  "notify_before": 30,
  "last_notification_at": "",
  "estimated_minutes": 120,
  "time_spent": 5,
  "time_entries": [{"id": "te1", "startedAt": "2026-06-15T08:00:00.000Z", "minutes": 5}],
  "snoozed_until": "",
  "client_updated_at": "2026-06-15T08:30:00.500Z",
  "client_created_at": "2026-06-01T10:00:00.000Z",
  "device_id": "device-A"
}
```

`GSDKit/Tests/GSDSyncTests/Fixtures/task_empty_dates.json` (empty-string dates + null numbers — the §7.1 absent forms):

```json
{
  "id": "rec_def456",
  "task_id": "task-2",
  "owner": "user-1",
  "title": "No due date",
  "description": "",
  "urgent": false,
  "important": false,
  "quadrant": "eliminate",
  "due_date": "",
  "completed": false,
  "completed_at": "",
  "recurrence": "none",
  "tags": [],
  "subtasks": [],
  "dependencies": [],
  "notification_enabled": true,
  "notification_sent": false,
  "notify_before": null,
  "last_notification_at": "",
  "estimated_minutes": null,
  "time_spent": 0,
  "time_entries": [],
  "snoozed_until": "",
  "client_updated_at": "2026-06-10T12:00:00.000Z",
  "client_created_at": "2026-06-10T12:00:00.000Z",
  "device_id": "device-B"
}
```

`GSDKit/Tests/GSDSyncTests/Fixtures/task_missing_fields.json` (only the join key + a couple fields present — everything else key-absent, must default without throwing):

```json
{
  "task_id": "task-3",
  "title": "Sparse record",
  "urgent": true,
  "important": false
}
```

`GSDKit/Tests/GSDSyncTests/Fixtures/task_list_with_malformed.json` (a list where the middle record is missing the required `task_id` — it must be SKIPPED, not abort the batch, §7.4):

```json
[
  {"task_id": "task-ok-1", "title": "first", "urgent": false, "important": true},
  {"title": "no task_id — malformed", "urgent": false, "important": false},
  {"task_id": "task-ok-2", "title": "third", "urgent": true, "important": true}
]
```

- [ ] **Step 2: Add the `Fixtures` resource to the `GSDSyncTests` target in `Package.swift`**

Change the `GSDSyncTests` test target line to (use **`.copy`**, NOT `.process` — PROBE-VERIFIED that `.copy` preserves the `Fixtures/` subdirectory so the `subdirectory:` lookup in Step 3 resolves; `.process` can flatten it):

```swift
        .testTarget(
            name: "GSDSyncTests",
            dependencies: ["GSDSync"],
            resources: [.copy("Fixtures")]
        ),
```

- [ ] **Step 3: Write the failing test** — `GSDKit/Tests/GSDSyncTests/PocketBaseTaskRecordTests.swift`:

```swift
import Testing
import Foundation
import GSDModel
@testable import GSDSync

struct PocketBaseTaskRecordTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
    private func decode(_ name: String) throws -> PocketBaseTaskRecord {
        try JSONDecoder().decode(PocketBaseTaskRecord.self, from: fixture(name))
    }

    @Test func decodesWellFormedRecord() throws {
        let r = try decode("task_well_formed")
        #expect(r.id == "rec_abc123")          // PocketBase record id
        #expect(r.taskId == "task-1")          // join key — distinct from record id
        #expect(r.title == "Ship sync")
        #expect(r.tags == ["work", "sync"])
        #expect(r.subtasks == [Subtask(id: "sub1", title: "design", completed: true)])
        #expect(r.dependencies == ["task-0"])
        #expect(r.notifyBefore == 30)
        #expect(r.timeEntries == [WireTimeEntry(id: "te1", startedAt: "2026-06-15T08:00:00.000Z", minutes: 5)])
        #expect(r.clientUpdatedAt == "2026-06-15T08:30:00.500Z")
    }

    @Test func emptyDatesAndNullNumbersDecode() throws {
        let r = try decode("task_empty_dates")
        #expect(r.dueDate == "")
        #expect(WireDate.parse(r.dueDate) == nil)
        #expect(r.notifyBefore == nil)         // JSON null → nil
        #expect(r.estimatedMinutes == nil)
        #expect(r.timeSpent == 0)
    }

    @Test func missingOptionalFieldsDefaultWithoutThrowing() throws {
        let r = try decode("task_missing_fields")   // only task_id/title/urgent/important present
        #expect(r.taskId == "task-3")
        #expect(r.description == "")
        #expect(r.recurrence == "none")
        #expect(r.tags == [])
        #expect(r.notificationEnabled == true)       // §5.1 default
        #expect(r.notifyBefore == nil)
        #expect(r.dueDate == "")                     // key-absent non-optional → defaulted
    }

    @Test func recordMissingTaskIdFailsToDecode() {
        let json = Data(#"{"title":"x","urgent":false,"important":false}"#.utf8)
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: json)
        }
    }

    @Test func decodeListSkipsMalformedRecords() throws {
        let records = try PocketBaseTaskRecord.decodeList(fixture("task_list_with_malformed"))
        #expect(records.count == 2)                  // the middle (no task_id) is skipped, not fatal
        #expect(records.map(\.taskId) == ["task-ok-1", "task-ok-2"])
    }
}
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `cd GSDKit && swift test --filter PocketBaseTaskRecordTests`
Expected: FAIL — `PocketBaseTaskRecord` is undefined (no such type) and the target won't compile.

- [ ] **Step 5: Implement `PocketBaseTaskRecord`** — `GSDKit/Sources/GSDSync/PocketBaseTaskRecord.swift`:

```swift
import Foundation
import GSDModel

/// The flattened wire form of a `TimeEntry` (§7.1): the wire drops `endedAt`/`notes` and carries
/// a whole-minute `minutes` duration. `startedAt` is a raw ISO-8601 string (parsed via `WireDate`).
struct WireTimeEntry: Codable, Equatable {
    var id: String
    var startedAt: String
    var minutes: Int
}

/// Faithful §7.1 PocketBase `tasks` record (snake_case wire model). Date fields are raw `String`s —
/// leniency lives in `WireDate`, not here. System `created`/`updated` are omitted (§7.1 forbids
/// using them for sort/filter). Decoding is DEFENSIVE: only `task_id` (the join key) is required;
/// every other field defaults so empty-string, JSON-null, and key-absent all decode without
/// throwing (mirrors the `Task.init(from:)` lenient-decode precedent). `Subtask` is reused from
/// `GSDModel` because it already matches the §7.1 `{id,title,completed}` shape.
struct PocketBaseTaskRecord: Codable, Equatable {
    var id: String                 // PocketBase record id (system) — distinct from task_id
    var taskId: String             // the app's Task.id — the join key
    var owner: String
    var title: String
    var description: String
    var urgent: Bool
    var important: Bool
    var quadrant: String
    var dueDate: String
    var completed: Bool
    var completedAt: String
    var recurrence: String
    var tags: [String]
    var subtasks: [Subtask]
    var dependencies: [String]
    var notificationEnabled: Bool
    var notificationSent: Bool
    var notifyBefore: Int?
    var lastNotificationAt: String
    var estimatedMinutes: Int?
    var timeSpent: Int
    var timeEntries: [WireTimeEntry]
    var snoozedUntil: String
    var clientUpdatedAt: String
    var clientCreatedAt: String
    var deviceId: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case owner, title, description, urgent, important, quadrant
        case dueDate = "due_date"
        case completed
        case completedAt = "completed_at"
        case recurrence, tags, subtasks, dependencies
        case notificationEnabled = "notification_enabled"
        case notificationSent = "notification_sent"
        case notifyBefore = "notify_before"
        case lastNotificationAt = "last_notification_at"
        case estimatedMinutes = "estimated_minutes"
        case timeSpent = "time_spent"
        case timeEntries = "time_entries"
        case snoozedUntil = "snoozed_until"
        case clientUpdatedAt = "client_updated_at"
        case clientCreatedAt = "client_created_at"
        case deviceId = "device_id"
    }

    /// Defensive decode (§7.1): `task_id` required; everything else defaults. `encode(to:)` stays
    /// synthesized (uses the snake_case `CodingKeys`; nil optionals are omitted via `encodeIfPresent`).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskId = try c.decode(String.self, forKey: .taskId)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        urgent = try c.decodeIfPresent(Bool.self, forKey: .urgent) ?? false
        important = try c.decodeIfPresent(Bool.self, forKey: .important) ?? false
        quadrant = try c.decodeIfPresent(String.self, forKey: .quadrant) ?? ""
        dueDate = try c.decodeIfPresent(String.self, forKey: .dueDate) ?? ""
        completed = try c.decodeIfPresent(Bool.self, forKey: .completed) ?? false
        completedAt = try c.decodeIfPresent(String.self, forKey: .completedAt) ?? ""
        recurrence = try c.decodeIfPresent(String.self, forKey: .recurrence) ?? "none"
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        subtasks = try c.decodeIfPresent([Subtask].self, forKey: .subtasks) ?? []
        dependencies = try c.decodeIfPresent([String].self, forKey: .dependencies) ?? []
        notificationEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationEnabled) ?? true
        notificationSent = try c.decodeIfPresent(Bool.self, forKey: .notificationSent) ?? false
        notifyBefore = try c.decodeIfPresent(Int.self, forKey: .notifyBefore)
        lastNotificationAt = try c.decodeIfPresent(String.self, forKey: .lastNotificationAt) ?? ""
        estimatedMinutes = try c.decodeIfPresent(Int.self, forKey: .estimatedMinutes)
        timeSpent = try c.decodeIfPresent(Int.self, forKey: .timeSpent) ?? 0
        timeEntries = try c.decodeIfPresent([WireTimeEntry].self, forKey: .timeEntries) ?? []
        snoozedUntil = try c.decodeIfPresent(String.self, forKey: .snoozedUntil) ?? ""
        clientUpdatedAt = try c.decodeIfPresent(String.self, forKey: .clientUpdatedAt) ?? ""
        clientCreatedAt = try c.decodeIfPresent(String.self, forKey: .clientCreatedAt) ?? ""
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
    }

    /// Memberwise init (the synthesized one is suppressed by the custom `init(from:)`); used by
    /// `TaskWireMapper.toWire`.
    init(id: String, taskId: String, owner: String, title: String, description: String,
         urgent: Bool, important: Bool, quadrant: String, dueDate: String, completed: Bool,
         completedAt: String, recurrence: String, tags: [String], subtasks: [Subtask],
         dependencies: [String], notificationEnabled: Bool, notificationSent: Bool,
         notifyBefore: Int?, lastNotificationAt: String, estimatedMinutes: Int?, timeSpent: Int,
         timeEntries: [WireTimeEntry], snoozedUntil: String, clientUpdatedAt: String,
         clientCreatedAt: String, deviceId: String) {
        self.id = id; self.taskId = taskId; self.owner = owner; self.title = title
        self.description = description; self.urgent = urgent; self.important = important
        self.quadrant = quadrant; self.dueDate = dueDate; self.completed = completed
        self.completedAt = completedAt; self.recurrence = recurrence; self.tags = tags
        self.subtasks = subtasks; self.dependencies = dependencies
        self.notificationEnabled = notificationEnabled; self.notificationSent = notificationSent
        self.notifyBefore = notifyBefore; self.lastNotificationAt = lastNotificationAt
        self.estimatedMinutes = estimatedMinutes; self.timeSpent = timeSpent
        self.timeEntries = timeEntries; self.snoozedUntil = snoozedUntil
        self.clientUpdatedAt = clientUpdatedAt; self.clientCreatedAt = clientCreatedAt
        self.deviceId = deviceId
    }
}

/// Decodes one element of an array independently, swallowing per-element errors so a single
/// malformed record yields `nil` rather than aborting the whole batch (§7.4 skip-malformed).
private struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

extension PocketBaseTaskRecord {
    /// Decode a PocketBase list payload, SKIPPING malformed records (§7.4) rather than failing the
    /// whole batch. Each element is decoded independently via `Failable`.
    static func decodeList(_ data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [PocketBaseTaskRecord] {
        try decoder.decode([Failable<PocketBaseTaskRecord>].self, from: data).compactMap(\.value)
    }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd GSDKit && swift test --filter PocketBaseTaskRecordTests`
Expected: PASS (5 tests). If `Bundle.module` returns nil (resource not found), confirm Step 2 uses `.copy("Fixtures")` (NOT `.process`, which can flatten the directory and break the `subdirectory:` lookup) and that the files are under `Tests/GSDSyncTests/Fixtures/`.

- [ ] **Step 7: Commit**

```bash
git add GSDKit/Package.swift GSDKit/Sources/GSDSync/PocketBaseTaskRecord.swift GSDKit/Tests/GSDSyncTests/PocketBaseTaskRecordTests.swift GSDKit/Tests/GSDSyncTests/Fixtures
git commit -m "feat(sync): add PocketBaseTaskRecord wire DTO + skip-malformed list decode (A42)"
```

---

### Task A3: `TaskWireMapper` (toWire / toDomain — reconstruct vs merge)

**Files:**
- Create: `GSDKit/Sources/GSDSync/TaskWireMapper.swift`
- Test: `GSDKit/Tests/GSDSyncTests/TaskWireMapperTests.swift`

> **Why two private helpers, not one `local?.field ?? remote`:** for an optional device-local field (e.g. `lastNotificationAt`), `local?.lastNotificationAt ?? remote` would fall through to the remote value whenever the local task exists but that field is legitimately nil — silently violating "never take device-local from remote." Branching on `local` existence (reconstruct vs merge) is the only correct shape (conventions 5–7).

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDSyncTests/TaskWireMapperTests.swift`:

```swift
import Testing
import Foundation
import GSDModel
@testable import GSDSync

struct TaskWireMapperTests {
    private func date(_ s: String) -> Date { WireDate.parse(s)! }

    private func sampleTask(
        timeEntries: [TimeEntry] = [],
        notificationSent: Bool = false,
        lastNotificationAt: Date? = nil,
        snoozedUntil: Date? = nil,
        parentTaskId: String? = nil,
        timeSpent: Int? = nil
    ) -> Task {
        Task(
            id: "task-1", title: "Ship", description: "do it",
            urgent: true, important: false,
            completed: false, completedAt: nil,
            createdAt: date("2026-06-01T10:00:00.000Z"),
            updatedAt: date("2026-06-15T08:30:00.500Z"),
            dueDate: date("2026-06-15T09:00:00.000Z"),
            recurrence: .weekly, tags: ["work"],
            subtasks: [Subtask(id: "s1", title: "design", completed: true)],
            dependencies: ["task-0"], parentTaskId: parentTaskId,
            notifyBefore: 30, notificationEnabled: true,
            notificationSent: notificationSent, lastNotificationAt: lastNotificationAt,
            snoozedUntil: snoozedUntil, estimatedMinutes: 120,
            timeSpent: timeSpent, timeEntries: timeEntries
        )
    }

    // MARK: toWire

    @Test func toWireMapsScalarsAndDerivesQuadrant() {
        let r = TaskWireMapper.toWire(sampleTask(), owner: "user-1", deviceId: "dev-A", recordId: "rec-9")
        #expect(r.id == "rec-9")                             // recordId param
        #expect(r.taskId == "task-1")                        // join key = Task.id
        #expect(r.owner == "user-1")
        #expect(r.deviceId == "dev-A")
        #expect(r.quadrant == Quadrant(urgent: true, important: false).rawValue)  // derived, not stored
        #expect(r.dueDate == "2026-06-15T09:00:00.000Z")
        #expect(r.completedAt == "")                         // nil Date → ""
        #expect(r.clientUpdatedAt == "2026-06-15T08:30:00.500Z")
        #expect(r.timeSpent == 0)                            // nil timeSpent → 0
    }

    @Test func toWireFlattensTimeEntries() {
        let start = date("2026-06-15T08:00:00.000Z")
        let task = sampleTask(timeEntries: [
            TimeEntry(id: "te1", startedAt: start, endedAt: start.addingTimeInterval(95), notes: "x"),
            TimeEntry(id: "te2", startedAt: start, endedAt: nil, notes: nil)   // running
        ])
        let r = TaskWireMapper.toWire(task, owner: "u", deviceId: "d")
        #expect(r.timeEntries == [
            WireTimeEntry(id: "te1", startedAt: "2026-06-15T08:00:00.000Z", minutes: 1),  // floor(95s)
            WireTimeEntry(id: "te2", startedAt: "2026-06-15T08:00:00.000Z", minutes: 0)   // running → 0
        ])
    }

    // MARK: toDomain — reconstruct (no local task)

    @Test func toDomainReconstructsWhenNoLocal() {
        let start = date("2026-06-15T08:00:00.000Z")
        let wire = TaskWireMapper.toWire(
            sampleTask(timeEntries: [TimeEntry(id: "te1", startedAt: start,
                                               endedAt: start.addingTimeInterval(120), notes: "n")]),
            owner: "u", deviceId: "d")
        let task = TaskWireMapper.toDomain(wire, mergingInto: nil)
        #expect(task.id == "task-1")                         // task_id → Task.id
        #expect(task.quadrant == Quadrant(urgent: true, important: false))  // recomputed from flags
        #expect(task.parentTaskId == nil)
        #expect(task.timeEntries.count == 1)
        #expect(task.timeEntries[0].endedAt == start.addingTimeInterval(120))  // synthesized startedAt+minutes
        #expect(task.timeEntries[0].notes == nil)            // documented loss
    }

    // MARK: toDomain — merge (local task exists)

    @Test func toDomainMergePreservesDeviceLocalAndDerivedFields() {
        let localStart = date("2026-06-10T07:00:00.000Z")
        let local = sampleTask(
            timeEntries: [TimeEntry(id: "local-te", startedAt: localStart,
                                    endedAt: localStart.addingTimeInterval(600), notes: "local note")],
            notificationSent: true,
            lastNotificationAt: date("2026-06-14T09:00:00.000Z"),
            snoozedUntil: date("2026-06-16T09:00:00.000Z"),
            parentTaskId: "parent-1",
            timeSpent: 10
        )
        // Remote has DIFFERENT title + its own (would-be) device-local values.
        var wire = TaskWireMapper.toWire(local, owner: "u", deviceId: "remote-dev")
        wire.title = "Remote title"
        wire.notificationSent = false
        wire.lastNotificationAt = ""
        wire.snoozedUntil = ""
        wire.timeSpent = 999
        wire.timeEntries = []   // remote lost the entries

        let merged = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(merged.title == "Remote title")                       // synced field ← remote
        #expect(merged.notificationSent == true)                      // device-local ← local
        #expect(merged.lastNotificationAt == date("2026-06-14T09:00:00.000Z"))
        #expect(merged.snoozedUntil == date("2026-06-16T09:00:00.000Z"))
        #expect(merged.parentTaskId == "parent-1")                    // no wire column → local
        #expect(merged.timeSpent == 10)                               // derived → tracks local entries
        #expect(merged.timeEntries == local.timeEntries)              // prefer-local (lossy wire)
    }

    @Test func mergePreservesLocalNilDeviceLocalFields() {
        // The trap: local exists but its device-local fields are nil — merge must KEEP nil, not pull remote.
        let local = sampleTask(notificationSent: false, lastNotificationAt: nil, snoozedUntil: nil)
        var wire = TaskWireMapper.toWire(local, owner: "u", deviceId: "d")
        wire.lastNotificationAt = "2026-06-14T09:00:00.000Z"          // remote has a value
        wire.snoozedUntil = "2026-06-16T09:00:00.000Z"
        let merged = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(merged.lastNotificationAt == nil)                     // local nil preserved, NOT remote
        #expect(merged.snoozedUntil == nil)
    }

    // MARK: round-trip

    @Test func roundTripPreservesJoinKeyAndDocumentsLoss() {
        let start = date("2026-06-15T08:00:00.000Z")
        let original = sampleTask(timeEntries: [TimeEntry(id: "te1", startedAt: start,
                                                          endedAt: start.addingTimeInterval(125), notes: "keep?")])
        let wire = TaskWireMapper.toWire(original, owner: "u", deviceId: "d", recordId: "rec-1")
        let restored = TaskWireMapper.toDomain(wire, mergingInto: nil)
        #expect(restored.id == original.id)                           // Task.id ↔ task_id preserved
        #expect(wire.id == "rec-1" && wire.id != wire.taskId)         // record id kept distinct from join key
        #expect(restored.title == original.title)
        #expect(restored.timeEntries[0].endedAt == start.addingTimeInterval(120))  // floored to 2 min (loss)
        #expect(restored.timeEntries[0].notes == nil)                 // notes lost (documented)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd GSDKit && swift test --filter TaskWireMapperTests`
Expected: FAIL — `TaskWireMapper` is undefined; target won't compile.

- [ ] **Step 3: Implement `TaskWireMapper`** — `GSDKit/Sources/GSDSync/TaskWireMapper.swift`:

```swift
import Foundation
import GSDModel

/// Bidirectional mapper between the local `Task` (camelCase, rich `timeEntries`) and the PocketBase
/// wire record (snake_case, flattened `time_entries`) — product spec §7.2. Pure: `owner`/`deviceId`/
/// `recordId` are parameters (the 5c push engine supplies them); no I/O, no identity lookup.
enum TaskWireMapper {

    // MARK: Local → Wire (push)

    static func toWire(_ task: Task, owner: String, deviceId: String, recordId: String = "") -> PocketBaseTaskRecord {
        PocketBaseTaskRecord(
            id: recordId,
            taskId: task.id,
            owner: owner,
            title: task.title,
            description: task.description,
            urgent: task.urgent,
            important: task.important,
            quadrant: task.quadrant.rawValue,
            dueDate: WireDate.format(task.dueDate),
            completed: task.completed,
            completedAt: WireDate.format(task.completedAt),
            recurrence: task.recurrence.rawValue,
            tags: task.tags,
            subtasks: task.subtasks,
            dependencies: task.dependencies,
            notificationEnabled: task.notificationEnabled,
            notificationSent: task.notificationSent,
            notifyBefore: task.notifyBefore,
            lastNotificationAt: WireDate.format(task.lastNotificationAt),
            estimatedMinutes: task.estimatedMinutes,
            timeSpent: task.timeSpent ?? 0,
            timeEntries: task.timeEntries.map(flatten),
            snoozedUntil: WireDate.format(task.snoozedUntil),
            clientUpdatedAt: WireDate.format(task.updatedAt),
            clientCreatedAt: WireDate.format(task.createdAt),
            deviceId: deviceId
        )
    }

    private static func flatten(_ entry: TimeEntry) -> WireTimeEntry {
        let minutes: Int
        if let ended = entry.endedAt {
            minutes = max(0, Int((ended.timeIntervalSince(entry.startedAt) / 60).rounded(.down)))
        } else {
            minutes = 0   // still-running entry
        }
        return WireTimeEntry(id: entry.id, startedAt: WireDate.format(entry.startedAt), minutes: minutes)
    }

    // MARK: Wire → Local (pull)

    /// `local == nil` → reconstruct best-effort; `local != nil` → merge (remote wins for synced
    /// fields, device-local + derived fields preserved from `local`). `quadrant` is always recomputed.
    static func toDomain(_ record: PocketBaseTaskRecord, mergingInto local: Task?) -> Task {
        guard let local else { return reconstructed(from: record) }
        return merged(record, into: local)
    }

    /// New-from-remote: reconstruct. No local lineage; device-local fields come from the wire.
    private static func reconstructed(from r: PocketBaseTaskRecord) -> Task {
        Task(
            id: r.taskId, title: r.title, description: r.description,
            urgent: r.urgent, important: r.important,
            completed: r.completed, completedAt: WireDate.parse(r.completedAt),
            createdAt: WireDate.parse(r.clientCreatedAt) ?? Date(timeIntervalSince1970: 0),
            updatedAt: WireDate.parse(r.clientUpdatedAt) ?? Date(timeIntervalSince1970: 0),
            dueDate: WireDate.parse(r.dueDate),
            recurrence: RecurrenceType(rawValue: r.recurrence) ?? .none,
            tags: r.tags, subtasks: r.subtasks, dependencies: r.dependencies,
            parentTaskId: nil,                              // §7.1 has no wire column
            notifyBefore: r.notifyBefore,
            notificationEnabled: r.notificationEnabled,
            notificationSent: r.notificationSent,
            lastNotificationAt: WireDate.parse(r.lastNotificationAt),
            snoozedUntil: WireDate.parse(r.snoozedUntil),
            estimatedMinutes: r.estimatedMinutes,
            timeSpent: r.timeSpent,
            timeEntries: r.timeEntries.map(reconstruct)
        )
    }

    /// Pull-merge into an existing local task: remote wins for synced fields; the device-local +
    /// derived set is preserved from `local` (conventions 7). `quadrant` recomputed from flags.
    private static func merged(_ r: PocketBaseTaskRecord, into local: Task) -> Task {
        Task(
            id: r.taskId, title: r.title, description: r.description,
            urgent: r.urgent, important: r.important,
            completed: r.completed, completedAt: WireDate.parse(r.completedAt),
            createdAt: WireDate.parse(r.clientCreatedAt) ?? local.createdAt,
            updatedAt: WireDate.parse(r.clientUpdatedAt) ?? local.updatedAt,
            dueDate: WireDate.parse(r.dueDate),
            recurrence: RecurrenceType(rawValue: r.recurrence) ?? .none,
            tags: r.tags, subtasks: r.subtasks, dependencies: r.dependencies,
            parentTaskId: local.parentTaskId,               // device-local (no wire column)
            notifyBefore: r.notifyBefore,
            notificationEnabled: r.notificationEnabled,
            notificationSent: local.notificationSent,       // device-local (§7.4)
            lastNotificationAt: local.lastNotificationAt,   // device-local (§7.4)
            snoozedUntil: local.snoozedUntil,               // device-local (§7.4)
            estimatedMinutes: r.estimatedMinutes,
            timeSpent: local.timeSpent,                     // derived from timeEntries → stays local
            timeEntries: local.timeEntries                  // wire form lossy → prefer local
        )
    }

    private static func reconstruct(_ wire: WireTimeEntry) -> TimeEntry {
        let started = WireDate.parse(wire.startedAt) ?? Date(timeIntervalSince1970: 0)
        return TimeEntry(id: wire.id, startedAt: started,
                         endedAt: started.addingTimeInterval(Double(wire.minutes) * 60), notes: nil)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd GSDKit && swift test --filter TaskWireMapperTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSync/TaskWireMapper.swift GSDKit/Tests/GSDSyncTests/TaskWireMapperTests.swift
git commit -m "feat(sync): add bidirectional TaskWireMapper (toWire/toDomain merge+reconstruct) (A44/A45)"
```

---

### Task A4: `LWW` (last-write-wins, ms-int comparison)

**Files:**
- Create: `GSDKit/Sources/GSDSync/LWW.swift`
- Test: `GSDKit/Tests/GSDSyncTests/LWWTests.swift`

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDSyncTests/LWWTests.swift`:

```swift
import Testing
import Foundation
@testable import GSDSync

struct LWWTests {
    private let t0 = Date(timeIntervalSince1970: 1000.000)
    private let t1 = Date(timeIntervalSince1970: 1000.500)   // +500 ms

    @Test func remoteNewerTakesRemote() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: t1) == .takeRemote)
    }

    @Test func localNewerKeepsLocal() {
        #expect(LWW.resolve(localUpdatedAt: t1, remoteClientUpdatedAt: t0) == .keepLocal)
    }

    @Test func equalMillisecondsIsNoOp() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: t0) == .noOp)
    }

    @Test func unparseableRemoteIsNoOp() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: nil) == .noOp)
    }

    @Test func noLocalTakesRemote() {
        #expect(LWW.resolve(localUpdatedAt: nil, remoteClientUpdatedAt: t0) == .takeRemote)
    }

    @Test func subMillisecondDifferenceInSameBucketIsNoOp() {
        let a = Date(timeIntervalSince1970: 1000.5000)
        let b = Date(timeIntervalSince1970: 1000.5004)   // same ms bucket
        #expect(LWW.resolve(localUpdatedAt: a, remoteClientUpdatedAt: b) == .noOp)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd GSDKit && swift test --filter LWWTests`
Expected: FAIL — `LWW` is undefined; target won't compile.

- [ ] **Step 3: Implement `LWW`** — `GSDKit/Sources/GSDSync/LWW.swift`:

```swift
import Foundation

/// Last-write-wins resolution keyed on `client_updated_at` (milliseconds) — product spec §7.3.
/// Guards both push and pull. Compares millisecond integers to match the web app exactly, so a
/// sub-millisecond difference that lands in the same bucket is a no-op (never an overwrite).
enum LWW {
    enum Decision: Equatable { case takeRemote, keepLocal, noOp }

    static func resolve(localUpdatedAt local: Date?, remoteClientUpdatedAt remote: Date?) -> Decision {
        guard let remote else { return .noOp }        // unparseable / missing remote timestamp
        guard let local else { return .takeRemote }   // no local task → take remote
        let l = ms(local), r = ms(remote)
        if r > l { return .takeRemote }
        if l > r { return .keepLocal }
        return .noOp                                   // equal ms → don't overwrite
    }

    private static func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd GSDKit && swift test --filter LWWTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Run the whole `GSDSync` suite + commit**

Run: `cd GSDKit && swift test --filter GSDSyncTests`
Expected: PASS (all of A1–A4: WireDate 7, PocketBaseTaskRecord 5, TaskWireMapper 6, LWW 6).

```bash
git add GSDKit/Sources/GSDSync/LWW.swift GSDKit/Tests/GSDSyncTests/LWWTests.swift
git commit -m "feat(sync): add LWW last-write-wins comparison (A46)"
```

---

## Group B — Sync queue persistence (`GSDStore`, `swift test`)

> The persisted push queue (§7.5). Built + tested here, **NOT wired to `TaskStore` mutations** (convention 10 — that hook is 5c). Run: `cd GSDKit && swift test --filter SyncQueueRepositoryTests`. Maps **A47**.

### Task B1: `SyncQueueItem` + `SyncQueueRecord` + v4 migration + `SyncQueueRepository`

**Files:**
- Create: `GSDKit/Sources/GSDStore/SyncQueueItem.swift`
- Create: `GSDKit/Sources/GSDStore/SyncQueueRecord.swift`
- Create: `GSDKit/Sources/GSDStore/SyncQueueRepository.swift`
- Modify: `GSDKit/Sources/GSDStore/Migrations.swift` (add `registerV4` + register it)
- Test: `GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift`

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift`:

```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct SyncQueueRepositoryTests {
    private func makeRepo() throws -> GRDBSyncQueueRepository {
        GRDBSyncQueueRepository(try AppDatabase.inMemory())
    }
    private func sampleTask(_ id: String) -> Task {
        Task(id: id, title: "t", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func enqueueAndFetchPendingRoundTripsPayload() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q1", taskId: "task-1", operation: .create,
                                             timestamp: 100, payload: sampleTask("task-1")))
        let pending = try await repo.pending()
        #expect(pending.count == 1)
        #expect(pending[0].id == "q1")
        #expect(pending[0].operation == .create)
        #expect(pending[0].payload?.id == "task-1")     // Task payload survived the JSON round-trip
    }

    @Test func deleteOperationHasNilPayload() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q-del", taskId: "task-9", operation: .delete,
                                             timestamp: 50, payload: nil))
        let pending = try await repo.pending()
        #expect(pending[0].operation == .delete)
        #expect(pending[0].payload == nil)              // nil payload round-trips as SQL NULL
    }

    @Test func pendingIsOrderedByTimestamp() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "b", taskId: "t", operation: .update, timestamp: 200))
        try await repo.enqueue(SyncQueueItem(id: "a", taskId: "t", operation: .update, timestamp: 100))
        #expect(try await repo.pending().map(\.id) == ["a", "b"])
    }

    @Test func failedItemsAreExcludedFromPendingButRetained() async throws {
        let repo = try makeRepo()
        var item = SyncQueueItem(id: "q1", taskId: "t", operation: .create, timestamp: 100)
        try await repo.enqueue(item)
        item.status = .failed; item.retryCount = 5; item.lastError = "boom"; item.failedAt = 999
        try await repo.update(item)
        #expect(try await repo.pending().isEmpty)       // failed → not drained by pending()
        item.status = .pending                          // retained, not dropped — re-mark and it returns
        try await repo.update(item)
        let back = try await repo.pending()
        #expect(back.count == 1 && back[0].retryCount == 5 && back[0].lastError == "boom")
    }

    @Test func removeDeletesTheItem() async throws {
        let repo = try makeRepo()
        try await repo.enqueue(SyncQueueItem(id: "q1", taskId: "t", operation: .update, timestamp: 100))
        try await repo.remove(id: "q1")
        #expect(try await repo.pending().isEmpty)
    }

    @Test func v4MigrationCoexistsWithEarlierTables() async throws {
        let db = try AppDatabase.inMemory()              // runs v1–v4
        let taskRepo = GRDBTaskRepository(db)
        try await taskRepo.upsert(sampleTask("task-1"))
        let queueRepo = GRDBSyncQueueRepository(db)
        try await queueRepo.enqueue(SyncQueueItem(id: "q1", taskId: "task-1", operation: .create,
                                                  timestamp: 1, payload: sampleTask("task-1")))
        #expect(try await taskRepo.fetchAll().count == 1)
        #expect(try await queueRepo.pending().count == 1)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd GSDKit && swift test --filter SyncQueueRepositoryTests`
Expected: FAIL — `SyncQueueItem`/`GRDBSyncQueueRepository` undefined; target won't compile.

- [ ] **Step 3: Create `SyncQueueItem`** — `GSDKit/Sources/GSDStore/SyncQueueItem.swift`:

```swift
import Foundation
import GSDModel

/// A queued local mutation awaiting push to PocketBase (§7.5). Persisted in the `syncQueue` table;
/// the 5c push engine drains the `.pending` items. `payload` is the full task for create/update,
/// nil for delete. Built in 5a; enqueue-on-mutation wiring lands in 5c.
public struct SyncQueueItem: Sendable, Identifiable, Equatable {
    public enum Operation: String, Codable, Sendable { case create, update, delete }
    public enum Status: String, Codable, Sendable { case pending, failed }

    public var id: String
    public var taskId: String
    public var operation: Operation
    public var timestamp: Int          // ms when queued
    public var retryCount: Int
    public var payload: Task?          // full task for create/update; nil for delete
    public var status: Status
    public var lastError: String?
    public var lastAttemptAt: Int?     // ms
    public var failedAt: Int?          // ms

    public init(id: String, taskId: String, operation: Operation, timestamp: Int,
                retryCount: Int = 0, payload: Task? = nil, status: Status = .pending,
                lastError: String? = nil, lastAttemptAt: Int? = nil, failedAt: Int? = nil) {
        self.id = id; self.taskId = taskId; self.operation = operation; self.timestamp = timestamp
        self.retryCount = retryCount; self.payload = payload; self.status = status
        self.lastError = lastError; self.lastAttemptAt = lastAttemptAt; self.failedAt = failedAt
    }
}
```

- [ ] **Step 4: Create `SyncQueueRecord`** — `GSDKit/Sources/GSDStore/SyncQueueRecord.swift`:

```swift
import Foundation
import GRDB
import GSDModel

/// GRDB row for a `SyncQueueItem` (§7.5). `payload` is the JSON-encoded `Task` (nil for delete),
/// stored as a nullable JSON string via `GSDJSON` (matching the embedded-collection convention in
/// `TaskRecord`). `operation`/`status` persist as their raw strings.
struct SyncQueueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncQueue"

    var id: String
    var taskId: String
    var operation: String
    var timestamp: Int
    var retryCount: Int
    var payload: String?          // JSON-encoded Task, or NULL for delete
    var status: String
    var lastError: String?
    var lastAttemptAt: Int?
    var failedAt: Int?
}

extension SyncQueueRecord {
    init(_ item: SyncQueueItem) throws {
        id = item.id
        taskId = item.taskId
        operation = item.operation.rawValue
        timestamp = item.timestamp
        retryCount = item.retryCount
        payload = try item.payload.map { try GSDJSON.string($0) }
        status = item.status.rawValue
        lastError = item.lastError
        lastAttemptAt = item.lastAttemptAt
        failedAt = item.failedAt
    }

    func toDomain() throws -> SyncQueueItem {
        SyncQueueItem(
            id: id,
            taskId: taskId,
            // .update / .pending fallbacks: a future/unknown raw value degrades gracefully rather
            // than failing the whole fetch (mirrors TaskRecord's recurrence `.none` defensiveness).
            operation: SyncQueueItem.Operation(rawValue: operation) ?? .update,
            timestamp: timestamp,
            retryCount: retryCount,
            payload: try payload.map { try GSDJSON.value(Task.self, $0) },
            status: SyncQueueItem.Status(rawValue: status) ?? .pending,
            lastError: lastError,
            lastAttemptAt: lastAttemptAt,
            failedAt: failedAt
        )
    }
}
```

- [ ] **Step 5: Add the v4 migration** — `GSDKit/Sources/GSDStore/Migrations.swift`. Add `registerV4(&migrator)` to the `migrator` property and the new function:

Change the `migrator` property to register v4:

```swift
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        registerV2(&migrator)
        registerV3(&migrator)
        registerV4(&migrator)
        return migrator
    }
```

Add the new migration function (alongside the others in the extension):

```swift
    static func registerV4(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v4") { db in
            try db.create(table: "syncQueue") { t in
                t.primaryKey("id", .text)
                t.column("taskId", .text).notNull().indexed()
                t.column("operation", .text).notNull()
                t.column("timestamp", .integer).notNull().indexed()
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("payload", .text)                       // JSON-encoded Task; NULL for delete
                t.column("status", .text).notNull().defaults(to: "pending").indexed()
                t.column("lastError", .text)
                t.column("lastAttemptAt", .integer)
                t.column("failedAt", .integer)
            }
        }
    }
```

- [ ] **Step 6: Create `SyncQueueRepository`** — `GSDKit/Sources/GSDStore/SyncQueueRepository.swift`:

```swift
import Foundation
import GRDB
import GSDModel

/// Async persistence for the push queue (§7.5). Holds NO business rules. Built in 5a; WIRED to
/// `TaskStore` mutations in 5c. `pending()` returns only `.pending` items (the push loop drains
/// these); `.failed` items stay in the table for manual retry and are surfaced separately later.
public protocol SyncQueueRepository: Sendable {
    func enqueue(_ item: SyncQueueItem) async throws
    func pending() async throws -> [SyncQueueItem]     // status == .pending, ordered by timestamp asc
    func update(_ item: SyncQueueItem) async throws
    func remove(id: String) async throws
}

public final class GRDBSyncQueueRepository: SyncQueueRepository {
    private let dbWriter: any DatabaseWriter

    public init(_ database: AppDatabase) {
        self.dbWriter = database.writer
    }

    public func enqueue(_ item: SyncQueueItem) async throws {
        let record = try SyncQueueRecord(item)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func pending() async throws -> [SyncQueueItem] {
        try await dbWriter.read { db in
            try SyncQueueRecord
                .filter(Column("status") == SyncQueueItem.Status.pending.rawValue)
                .order(Column("timestamp"))
                .fetchAll(db)
                .map { try $0.toDomain() }
        }
    }

    public func update(_ item: SyncQueueItem) async throws {
        let record = try SyncQueueRecord(item)
        try await dbWriter.write { db in try record.save(db) }   // save = insert-or-update by primary key
    }

    public func remove(id: String) async throws {
        try await dbWriter.write { db in _ = try SyncQueueRecord.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd GSDKit && swift test --filter SyncQueueRepositoryTests`
Expected: PASS (6 tests).

- [ ] **Step 8: Commit**

```bash
git add GSDKit/Sources/GSDStore/SyncQueueItem.swift GSDKit/Sources/GSDStore/SyncQueueRecord.swift GSDKit/Sources/GSDStore/SyncQueueRepository.swift GSDKit/Sources/GSDStore/Migrations.swift GSDKit/Tests/GSDStoreTests/SyncQueueRepositoryTests.swift
git commit -m "feat(sync): add persisted SyncQueue (v4 table + repository, unwired) (A47)"
```

---

## Group C — Device identity (`GSDStore`, `swift test`)

> Stable per-device identity (§7.8) persisted in the App-Group container. Injectable defaults suite + name source (convention 12). Run: `cd GSDKit && swift test --filter DeviceIdentityTests`. Maps **A48**.

### Task C1: `DeviceIdentity` + `AppGroupDefaults` keys

**Files:**
- Create: `GSDKit/Sources/GSDStore/DeviceIdentity.swift`
- Modify: `GSDKit/Sources/GSDStore/AppGroupDefaults.swift` (add `Key.deviceId` / `Key.deviceName`)
- Test: `GSDKit/Tests/GSDStoreTests/DeviceIdentityTests.swift`

- [ ] **Step 1: Write the failing test** — `GSDKit/Tests/GSDStoreTests/DeviceIdentityTests.swift`:

```swift
import Testing
import Foundation
@testable import GSDStore

struct DeviceIdentityTests {
    /// A fresh, isolated UserDefaults suite per test (never the shared App-Group one).
    private func freshDefaults() -> UserDefaults {
        let suite = "test.deviceidentity.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func generatesAndPersistsAStableDeviceId() {
        let defaults = freshDefaults()
        var generated = 0
        let make: () -> String = { generated += 1; return "uuid-\(generated)" }
        let first = DeviceIdentity.current(defaults: defaults, newID: make, nameProvider: { "iPhone" })
        let second = DeviceIdentity.current(defaults: defaults, newID: make, nameProvider: { "iPhone" })
        #expect(first.deviceId == "uuid-1")
        #expect(second.deviceId == "uuid-1")     // reused, not regenerated
        #expect(generated == 1)                   // newID called exactly once
    }

    @Test func capturesDeviceName() {
        let defaults = freshDefaults()
        let identity = DeviceIdentity.current(defaults: defaults, newID: { "x" }, nameProvider: { "Vinny's iPad" })
        #expect(identity.deviceName == "Vinny's iPad")
        #expect(defaults.string(forKey: AppGroupDefaults.Key.deviceName) == "Vinny's iPad")
    }

    @Test func refreshesNameOnRenameButKeepsId() {
        let defaults = freshDefaults()
        _ = DeviceIdentity.current(defaults: defaults, newID: { "x" }, nameProvider: { "Old Name" })
        let renamed = DeviceIdentity.current(defaults: defaults, newID: { "x" }, nameProvider: { "New Name" })
        #expect(renamed.deviceId == "x")          // id stable across rename
        #expect(renamed.deviceName == "New Name")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd GSDKit && swift test --filter DeviceIdentityTests`
Expected: FAIL — `DeviceIdentity` and `AppGroupDefaults.Key.deviceId`/`.deviceName` are undefined.

- [ ] **Step 3: Add the App-Group keys** — in `GSDKit/Sources/GSDStore/AppGroupDefaults.swift`, add to the `Key` enum (after the existing notification keys):

```swift
        public static let deviceId = "deviceId"
        public static let deviceName = "deviceName"
```

- [ ] **Step 4: Create `DeviceIdentity`** — `GSDKit/Sources/GSDStore/DeviceIdentity.swift`:

```swift
import Foundation

/// Stable per-device identity (§7.8): a persisted `deviceId` (UUID) generated once, plus a human
/// `deviceName`. Populates `device_id` on pushed records (echo filtering) and the sync-history /
/// device list. Stored in the App-Group container so extensions share identity. The defaults suite
/// + name source are injectable so the logic is deterministic in tests and the package stays
/// UIKit-free (the App passes `UIDevice.current.name` at the call site).
public struct DeviceIdentity: Sendable, Equatable {
    public let deviceId: String
    public let deviceName: String

    /// Returns the existing identity, or generates + persists a new `deviceId` on first call.
    /// `deviceName` is refreshed from `nameProvider` each call (a device can be renamed).
    public static func current(
        defaults: UserDefaults = AppGroupDefaults.shared,
        newID: () -> String = { UUID().uuidString },
        nameProvider: () -> String = { "Unknown Device" }
    ) -> DeviceIdentity {
        let id: String
        if let existing = defaults.string(forKey: AppGroupDefaults.Key.deviceId) {
            id = existing
        } else {
            id = newID()
            defaults.set(id, forKey: AppGroupDefaults.Key.deviceId)
        }
        let name = nameProvider()
        defaults.set(name, forKey: AppGroupDefaults.Key.deviceName)
        return DeviceIdentity(deviceId: id, deviceName: name)
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd GSDKit && swift test --filter DeviceIdentityTests`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add GSDKit/Sources/GSDStore/DeviceIdentity.swift GSDKit/Sources/GSDStore/AppGroupDefaults.swift GSDKit/Tests/GSDStoreTests/DeviceIdentityTests.swift
git commit -m "feat(sync): add persisted DeviceIdentity (§7.8) (A48)"
```

---

## Definition of Done (Phase 5a)

- [ ] **Full package suite green:** `cd GSDKit && swift test` passes — the existing 268 tests plus the new `GSDSyncTests` (WireDate 7, PocketBaseTaskRecord 5, TaskWireMapper 6, LWW 6) and `GSDStoreTests` additions (SyncQueueRepository 6, DeviceIdentity 3). No existing test regressed.
- [ ] **Acceptance criteria A42–A48** each map to passing tests (see per-task labels).
- [ ] **App regression smoke (no functional change in 5a):** build + launch + screenshot on **iPhone 17** and **iPad Pro 13-inch (M5)** simulators. Nothing in `App/` consumes `GSDSync` (its `project.yml` dependency is deferred to 5c), and there is **no `project.yml` change**, so **`xcodegen generate` is NOT required**; SPM picks up the new package sources automatically. The smoke only confirms `GSDStore`'s new files still compile/link and the app launches unchanged. (Fallback: if `xcodebuild` reports a package-resolution error, run `xcodegen generate` and rebuild.)
- [ ] **Scope fences held:** no networking/auth/engine/UI; `GSDSync` imports only `GSDModel` (NOT GRDB/GSDStore); `SyncQueueRepository` is **not** wired to `TaskStore` mutations; `GSDModel` untouched.
- [ ] **5b carry-forward noted:** reconcile the spec-authored fixtures against real `api.vinny.io` responses; verify the email-keying convergence empirically; the mapper's `owner`/`recordId` parameters get supplied by the push engine.

## Out of scope (explicit — deferred to 5b/5c/5d)

Networking (REST client, OAuth via `ASWebAuthenticationSession`, Keychain, token refresh) → 5b. Pull/push engines, single-flight coordinator, **enqueue-on-mutation wiring**, sync-history recording → 5c. SSE realtime, periodic safety net, health monitoring, sync-status UI / pull-to-refresh / history screen → 5c/5d. `owner`/auth resolution → 5b.
