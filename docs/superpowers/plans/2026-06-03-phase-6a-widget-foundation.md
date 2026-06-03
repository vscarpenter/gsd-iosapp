# Phase 6a — Native Foundation + Today's Focus Widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a Today's Focus home-screen widget backed by a precomputed App-Group snapshot, plus the reusable foundation (a GRDB-free shared module, the snapshot refresh pathway, and `gsd://` deep-linking).

**Architecture:** A new GRDB-free SwiftPM library `GSDSnapshot` (depends on GSDModel only) holds the app↔widget contract: a Codable `WidgetSnapshot`, an atomic App-Group `WidgetSnapshotStore`, a pure `WidgetSnapshotBuilder` that reuses the existing `today-focus` smart view, and the `gsd://` deep-link route. The app (the only GRDB owner, via `TaskStore`) writes the snapshot whenever its task set changes — driven by a new `TaskStore.onTasksChanged` callback — then calls `WidgetCenter.reloadAllTimelines()`. A new `GSDWidgets` app-extension target reads the snapshot and renders it; tapping it opens the app via `.onOpenURL`.

**Tech Stack:** Swift 6, swift-testing (`@Test`/`#expect`), SwiftUI, WidgetKit, XcodeGen (`project.yml` is the source of truth — `App/Info.plist` is generated from it), GRDB (only in GSDStore; the widget is GRDB-free).

**Spec:** `docs/specs/2026-06-03-phase-6a-widget-foundation.md`

**Key environment facts (verified):**
- Package tests run from `GSDKit/` via `swift test`. Targeted runs: `swift test --filter <SuiteName>`.
- App/extension build: `xcodegen generate` then `xcodebuild -project GSD.xcodeproj -scheme GSD ...`. The `GSD` scheme builds the app **and** its embedded extension.
- Simulators present: `iPhone 17 Pro`, `iPad Pro 13-inch (M5)` (both bootable).
- `App/Info.plist` is XcodeGen-generated from `project.yml` `info.properties`. **Never hand-edit it.**
- `Task(id:title:urgent:important:completed:createdAt:updatedAt:dueDate:…)` — `description`, `completed`, `dueDate`, etc. have defaults (per existing tests).
- Observer-await test idiom: `var waited = 0; while <cond> && waited < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1 }`.

---

## Task Sequence Overview

1. GSDModel — `AppGroup.id` constant + repoint `StoreLocation`
2. GSDSnapshot module scaffold + `WidgetSnapshot` type
3. `WidgetSnapshotBuilder` (pure projection)
4. `WidgetSnapshotStore` (atomic App-Group JSON)
5. `DeepLinkRoute` + `DeepLinkParser`
6. `TaskStore.onTasksChanged` callback
7. App — `WidgetSnapshotRefresher` + wire into `GSDApp` (+ project.yml GSDSnapshot dep)
8. `GSDWidgets` extension target + widget code (+ project.yml target/embed/NSExtension)
9. Deep-link app wiring — `CFBundleURLTypes` (project.yml) + `ContentView.onOpenURL`
10. Integration — regenerate, build both sims, `simctl openurl`, full `swift test`

Tasks 1–6 are pure package work verified by `swift test`. Tasks 7–9 are app/extension work verified by `xcodebuild`. Task 10 is the integration gate.

---

## Task 1: GSDModel — `AppGroup.id` constant + repoint `StoreLocation`

Single source of truth for the App-Group ID, in the GRDB-free GSDModel so both GSDStore and GSDSnapshot share it.

**Files:**
- Create: `GSDKit/Sources/GSDModel/AppGroup.swift`
- Create: `GSDKit/Tests/GSDModelTests/AppGroupTests.swift`
- Modify: `GSDKit/Sources/GSDStore/StoreLocation.swift:1-9`
- Create: `GSDKit/Tests/GSDStoreTests/StoreLocationTests.swift`

- [ ] **Step 1: Write the failing test for the constant**

Create `GSDKit/Tests/GSDModelTests/AppGroupTests.swift`:

```swift
import Testing
import GSDModel

struct AppGroupTests {
    @Test func idMatchesEntitlementString() {
        // Must match com.apple.security.application-groups in every target's entitlements.
        #expect(AppGroup.id == "group.dev.vinny.gsd")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd GSDKit && swift test --filter AppGroupTests`
Expected: FAIL — `cannot find 'AppGroup' in scope`.

- [ ] **Step 3: Create the constant**

Create `GSDKit/Sources/GSDModel/AppGroup.swift`:

```swift
import Foundation

/// The App Group container shared by the app and its extensions (widgets in Phase 6a).
/// This is the single source of truth for the identifier; it MUST match the
/// `com.apple.security.application-groups` entitlement in every target.
public enum AppGroup {
    public static let id = "group.dev.vinny.gsd"
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd GSDKit && swift test --filter AppGroupTests`
Expected: PASS.

- [ ] **Step 5: Repoint `StoreLocation` to the shared constant**

Modify `GSDKit/Sources/GSDStore/StoreLocation.swift` — add the GSDModel import and reference `AppGroup.id`:

```swift
import Foundation
import GSDModel

/// Resolves the on-disk database location. Prefers the App Group container so
/// Phase 6 widgets/extensions share one store; falls back to Application Support
/// when the group is unavailable (e.g. a plain simulator run without the
/// entitlement). This is the single place the path is decided (increment spec §3.1).
public enum StoreLocation {
    public static let appGroupID = AppGroup.id
    public static let databaseFileName = "gsd.sqlite"
```

(Leave the rest of the file — `databaseURL(fileManager:)` — unchanged.)

- [ ] **Step 6: Write the test guarding the repoint**

Create `GSDKit/Tests/GSDStoreTests/StoreLocationTests.swift`:

```swift
import Testing
import GSDModel
import GSDStore

struct StoreLocationTests {
    @Test func appGroupIDStaysInSyncWithSharedConstant() {
        #expect(StoreLocation.appGroupID == AppGroup.id)
        #expect(StoreLocation.appGroupID == "group.dev.vinny.gsd")
    }
}
```

- [ ] **Step 7: Run both suites to verify pass**

Run: `cd GSDKit && swift test --filter AppGroupTests && swift test --filter StoreLocationTests`
Expected: PASS for both.

- [ ] **Step 8: Commit**

```bash
git add GSDKit/Sources/GSDModel/AppGroup.swift GSDKit/Tests/GSDModelTests/AppGroupTests.swift GSDKit/Sources/GSDStore/StoreLocation.swift GSDKit/Tests/GSDStoreTests/StoreLocationTests.swift
git commit -m "feat(6a): add AppGroup.id shared constant; repoint StoreLocation"
```

---

## Task 2: GSDSnapshot module scaffold + `WidgetSnapshot` type

Create the GRDB-free shared library and its Codable transport type.

**Files:**
- Modify: `GSDKit/Package.swift`
- Create: `GSDKit/Sources/GSDSnapshot/WidgetSnapshot.swift`
- Create: `GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotTests.swift`

- [ ] **Step 1: Add the library, target, and test target to `Package.swift`**

In `GSDKit/Package.swift`, add to `products`:

```swift
        .library(name: "GSDSnapshot", targets: ["GSDSnapshot"]),
```

add to `targets` (after the `GSDSync` target):

```swift
        .target(name: "GSDSnapshot", dependencies: ["GSDModel"]),
```

and add a test target (after `GSDStoreTests`):

```swift
        .testTarget(name: "GSDSnapshotTests", dependencies: ["GSDSnapshot"]),
```

- [ ] **Step 2: Write the failing Codable round-trip test**

Create `GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotTests.swift`:

```swift
import Testing
import Foundation
import GSDSnapshot

struct WidgetSnapshotTests {
    @Test func codableRoundTrip() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 7),
            tasks: [WidgetTask(id: "x", title: "Title", dueDate: Date(timeIntervalSince1970: 9))],
            totalCount: 5)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(back == snap)
    }

    @Test func emptyHasNoTasks() {
        #expect(WidgetSnapshot.empty.tasks.isEmpty)
        #expect(WidgetSnapshot.empty.totalCount == 0)
    }
}
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd GSDKit && swift test --filter WidgetSnapshotTests`
Expected: FAIL — `no such module 'GSDSnapshot'` (or `cannot find 'WidgetSnapshot'`).

- [ ] **Step 4: Create the type**

Create `GSDKit/Sources/GSDSnapshot/WidgetSnapshot.swift`:

```swift
import Foundation

/// The lightweight, GRDB-free payload the app writes and the widget reads (spec §4.2).
/// `tasks` is already limited; `totalCount` is the full count of matches (for "+N more").
public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var tasks: [WidgetTask]
    public var totalCount: Int

    public init(generatedAt: Date, tasks: [WidgetTask], totalCount: Int) {
        self.generatedAt = generatedAt
        self.tasks = tasks
        self.totalCount = totalCount
    }

    /// Shown when no snapshot exists yet or nothing matches.
    public static let empty = WidgetSnapshot(generatedAt: .distantPast, tasks: [], totalCount: 0)

    /// Representative data for the widget gallery / placeholder previews.
    public static let sample = WidgetSnapshot(
        generatedAt: Date(timeIntervalSince1970: 0),
        tasks: [
            WidgetTask(id: "s1", title: "Ship the release", dueDate: nil),
            WidgetTask(id: "s2", title: "Reply to the board", dueDate: nil),
            WidgetTask(id: "s3", title: "Finalize the deck", dueDate: nil),
        ],
        totalCount: 5)
}

/// One row in the widget. Minimal by design — every Today's Focus row is urgent+important.
public struct WidgetTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var dueDate: Date?

    public init(id: String, title: String, dueDate: Date?) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
    }
}
```

- [ ] **Step 5: Run it to verify it passes**

Run: `cd GSDKit && swift test --filter WidgetSnapshotTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add GSDKit/Package.swift GSDKit/Sources/GSDSnapshot/WidgetSnapshot.swift GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotTests.swift
git commit -m "feat(6a): scaffold GSDSnapshot module + WidgetSnapshot type"
```

---

## Task 3: `WidgetSnapshotBuilder` (pure projection)

Project the app's task set onto the snapshot by reusing the existing `today-focus` smart view criteria + `TaskFilter` — zero new query logic, so the widget can never drift from the in-app view.

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/WidgetSnapshotBuilder.swift`
- Create: `GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotBuilderTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotBuilderTests.swift`:

```swift
import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct WidgetSnapshotBuilderTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }

    private func task(_ id: String, urgent: Bool, important: Bool,
                      completed: Bool = false, due: Date? = nil) -> Task {
        Task(id: id, title: id, urgent: urgent, important: important, completed: completed,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             dueDate: due)
    }

    @Test func includesOnlyUrgentImportantActive() {
        let tasks = [
            task("q1", urgent: true, important: true),
            task("q2", urgent: false, important: true),
            task("q3", urgent: true, important: false),
            task("q4", urgent: false, important: false),
            task("done", urgent: true, important: true, completed: true),
        ]
        let snap = WidgetSnapshotBuilder.todaysFocus(from: tasks, now: now, calendar: cal)
        #expect(snap.tasks.map(\.id) == ["q1"])
        #expect(snap.totalCount == 1)
    }

    @Test func sortsByDueDateAndRespectsLimitButCountsAll() {
        let day: TimeInterval = 86_400
        let tasks = (0..<10).map {
            task("t\($0)", urgent: true, important: true,
                 due: Date(timeIntervalSince1970: 1_000_000 + Double($0) * day))
        }
        let snap = WidgetSnapshotBuilder.todaysFocus(from: tasks, now: now, calendar: cal, limit: 3)
        #expect(snap.tasks.map(\.id) == ["t0", "t1", "t2"])  // earliest due first
        #expect(snap.totalCount == 10)                        // full match count, not the limit
    }

    @Test func emptyWhenNoMatches() {
        let snap = WidgetSnapshotBuilder.todaysFocus(
            from: [task("q4", urgent: false, important: false)], now: now, calendar: cal)
        #expect(snap.tasks.isEmpty)
        #expect(snap.totalCount == 0)
    }

    @Test func stampsGeneratedAtWithNow() {
        let snap = WidgetSnapshotBuilder.todaysFocus(from: [], now: now, calendar: cal)
        #expect(snap.generatedAt == now)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd GSDKit && swift test --filter WidgetSnapshotBuilderTests`
Expected: FAIL — `cannot find 'WidgetSnapshotBuilder' in scope`.

- [ ] **Step 3: Implement the builder**

Create `GSDKit/Sources/GSDSnapshot/WidgetSnapshotBuilder.swift`:

```swift
import Foundation
import GSDModel

/// Pure projection of the app's task set onto the Today's Focus snapshot (spec §5).
/// Reuses the SAME `today-focus` criteria + `TaskFilter` the in-app smart view uses.
public enum WidgetSnapshotBuilder {
    public static let todaysFocusViewID = "today-focus"

    public static func todaysFocus(
        from tasks: [Task], now: Date, calendar: Calendar = .current, limit: Int = 8
    ) -> WidgetSnapshot {
        let criteria = BuiltInSmartViews.all
            .first { $0.id == todaysFocusViewID }!.criteria   // static built-in: always present
        let matched = TaskFilter.apply(criteria, to: tasks, now: now, calendar: calendar)
        let rows = matched.prefix(limit).map {
            WidgetTask(id: $0.id, title: $0.title, dueDate: $0.dueDate)
        }
        return WidgetSnapshot(generatedAt: now, tasks: Array(rows), totalCount: matched.count)
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd GSDKit && swift test --filter WidgetSnapshotBuilderTests`
Expected: PASS (all four tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSnapshot/WidgetSnapshotBuilder.swift GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotBuilderTests.swift
git commit -m "feat(6a): WidgetSnapshotBuilder reuses today-focus smart view"
```

---

## Task 4: `WidgetSnapshotStore` (atomic App-Group JSON)

Cross-process transport: app writes atomically, widget reads and degrades to nil on missing/corrupt.

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/WidgetSnapshotStore.swift`
- Create: `GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotStoreTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotStoreTests.swift`:

```swift
import Testing
import Foundation
import GSDSnapshot

struct WidgetSnapshotStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var sample: WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 42),
                       tasks: [WidgetTask(id: "a", title: "A", dueDate: nil)], totalCount: 1)
    }

    @Test func roundTrips() throws {
        let store = WidgetSnapshotStore(containerURL: try tempDir())
        try store.write(sample)
        #expect(store.read() == sample)
    }

    @Test func readReturnsNilWhenMissing() throws {
        let store = WidgetSnapshotStore(containerURL: try tempDir())
        #expect(store.read() == nil)
    }

    @Test func readReturnsNilWhenCorrupt() throws {
        let dir = try tempDir()
        let store = WidgetSnapshotStore(containerURL: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(WidgetSnapshotStore.fileName))
        #expect(store.read() == nil)
    }

    @Test func writeOverwritesPrevious() throws {
        let store = WidgetSnapshotStore(containerURL: try tempDir())
        try store.write(sample)
        let updated = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 99), tasks: [], totalCount: 0)
        try store.write(updated)
        #expect(store.read() == updated)
    }

    @Test func writeThrowsWithoutContainer() {
        let store = WidgetSnapshotStore(containerURL: nil)
        #expect(throws: WidgetSnapshotError.self) { try store.write(sample) }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd GSDKit && swift test --filter WidgetSnapshotStoreTests`
Expected: FAIL — `cannot find 'WidgetSnapshotStore' in scope`.

- [ ] **Step 3: Implement the store**

Create `GSDKit/Sources/GSDSnapshot/WidgetSnapshotStore.swift`:

```swift
import Foundation
import GSDModel

/// Reads/writes the widget snapshot in the App-Group container (spec §4.2).
/// Writes are atomic (write-temp-then-rename) so the widget never reads a partial file.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-today-focus.json"
    private let containerURL: URL?

    /// Production: resolves the App-Group container (pure Foundation; GRDB-free).
    public init(appGroupID: String = AppGroup.id, fileManager: FileManager = .default) {
        self.containerURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Test seam: inject a temp directory (or nil to simulate a missing container).
    public init(containerURL: URL?) { self.containerURL = containerURL }

    private var fileURL: URL? { containerURL?.appendingPathComponent(Self.fileName) }

    public func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = fileURL else { throw WidgetSnapshotError.noContainer }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Returns nil on missing/unreadable/corrupt — first launch and decode failures degrade to empty.
    public func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

public enum WidgetSnapshotError: Error { case noContainer }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd GSDKit && swift test --filter WidgetSnapshotStoreTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSnapshot/WidgetSnapshotStore.swift GSDKit/Tests/GSDSnapshotTests/WidgetSnapshotStoreTests.swift
git commit -m "feat(6a): atomic App-Group WidgetSnapshotStore"
```

---

## Task 5: `DeepLinkRoute` + `DeepLinkParser`

The shared link contract: the widget builds the URL, the app parses it. Crucially ignores `gsd://oauth-callback` so a stray ASWebAuthenticationSession callback is a no-op.

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/DeepLink.swift`
- Create: `GSDKit/Tests/GSDSnapshotTests/DeepLinkParserTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `GSDKit/Tests/GSDSnapshotTests/DeepLinkParserTests.swift`:

```swift
import Testing
import Foundation
import GSDSnapshot

struct DeepLinkParserTests {
    @Test func parsesFocus() {
        #expect(DeepLinkParser.route(from: URL(string: "gsd://focus")!) == .focus)
    }

    @Test func ignoresOAuthCallback() {
        // ASWebAuthenticationSession's callback must never trigger app navigation.
        #expect(DeepLinkParser.route(from: URL(string: "gsd://oauth-callback")!) == nil)
    }

    @Test func ignoresForeignScheme() {
        #expect(DeepLinkParser.route(from: URL(string: "https://focus")!) == nil)
    }

    @Test func ignoresUnknownHost() {
        #expect(DeepLinkParser.route(from: URL(string: "gsd://nonsense")!) == nil)
    }

    @Test func routeURLRoundTrips() {
        #expect(DeepLinkParser.route(from: DeepLinkRoute.focus.url) == .focus)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd GSDKit && swift test --filter DeepLinkParserTests`
Expected: FAIL — `cannot find 'DeepLinkParser' in scope`.

- [ ] **Step 3: Implement the route + parser**

Create `GSDKit/Sources/GSDSnapshot/DeepLink.swift`:

```swift
import Foundation

/// App routes reachable via the `gsd://` scheme (spec §4.2 / §7).
public enum DeepLinkRoute: Equatable, Sendable {
    case focus
    public var url: URL { URL(string: "gsd://focus")! }
}

public enum DeepLinkParser {
    /// Maps a `gsd://` URL to a route. Returns nil for anything we don't own —
    /// crucially `gsd://oauth-callback`, so a stray delivery to .onOpenURL is ignored.
    public static func route(from url: URL) -> DeepLinkRoute? {
        guard url.scheme == "gsd" else { return nil }
        switch url.host {
        case "focus": return .focus
        default:      return nil   // includes "oauth-callback"
        }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd GSDKit && swift test --filter DeepLinkParserTests`
Expected: PASS (all five tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSnapshot/DeepLink.swift GSDKit/Tests/GSDSnapshotTests/DeepLinkParserTests.swift
git commit -m "feat(6a): gsd:// DeepLinkRoute + parser (ignores oauth-callback)"
```

---

## Task 6: `TaskStore.onTasksChanged` callback

Fire a callback after every observed task-set change (local edits, remote SSE/pull, background sync) so the app can rebuild the widget snapshot. Mirrors the existing `onMutation` hook.

**Files:**
- Modify: `GSDKit/Sources/GSDStore/TaskStore.swift:46-47` (add property) and `:87` (fire in observer)
- Modify: `GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift` (add a test)

- [ ] **Step 1: Write the failing test**

Add this test to `GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift` (inside the `TaskStoreEnqueueTests` struct, after `mutationFiresOnMutationHook`). It reuses the existing `makeStore(_:)` helper and the observer-await idiom:

```swift
    @Test func observerFiresOnTasksChangedHook() async throws {
        let q = RecordingQueue(); let store = try makeStore(q)
        final class Counter: @unchecked Sendable { var n = 0 }
        let counter = Counter()
        store.onTasksChanged = { counter.n += 1 }
        store.start()
        try await store.add(ParsedCapture(title: "Quick", urgent: true, important: false,
                                          tags: [], descriptionAdditions: []))
        // The GRDB observer emits asynchronously; drain until the hook fires.
        var waited = 0
        while counter.n == 0 && waited < 100 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1
        }
        #expect(counter.n >= 1)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd GSDKit && swift test --filter TaskStoreEnqueueTests/observerFiresOnTasksChangedHook`
Expected: FAIL — `value of type 'TaskStore' has no member 'onTasksChanged'`.

- [ ] **Step 3: Add the property**

In `GSDKit/Sources/GSDStore/TaskStore.swift`, after the `onMutation` declaration (line 47), add:

```swift
    /// Fired after every observed task-set change (local + remote + background sync), with the
    /// new value already committed to `tasks`. Drives the widget snapshot (6a). Not observed.
    @ObservationIgnored public var onTasksChanged: (() -> Void)?
```

- [ ] **Step 4: Fire it in the observer loop**

In `startTaskObserver()` (line 87), change the loop body to fire the hook after the assignment:

```swift
    private func startTaskObserver() {
        guard observerTask == nil else { return }
        let stream = repository.observeAll()
        observerTask = _Concurrency.Task { [weak self] in
            do { for try await snapshot in stream { self?.tasks = snapshot; self?.onTasksChanged?() } } catch {}
        }
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `cd GSDKit && swift test --filter TaskStoreEnqueueTests`
Expected: PASS (the new test plus the existing enqueue tests).

- [ ] **Step 6: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreEnqueueTests.swift
git commit -m "feat(6a): TaskStore.onTasksChanged fires after observed changes"
```

---

## Task 7: App — `WidgetSnapshotRefresher` + wire into `GSDApp`

The app-side writer: debounce task-change bursts, rebuild the snapshot, reload widget timelines. Add the GSDSnapshot dependency to the app target.

> **No unit test:** the refresher calls `WidgetCenter.reloadAllTimelines()` (no widget host in a package test) and the app has no test target. Its building blocks (`WidgetSnapshotBuilder`, `WidgetSnapshotStore`) are already covered; the refresher itself is verified by the build here and the simctl smoke in Task 10.

**Files:**
- Create: `App/Widgets/WidgetSnapshotRefresher.swift`
- Modify: `App/GSDApp.swift`
- Modify: `project.yml` (add GSDSnapshot product dep to the `GSD` target)

- [ ] **Step 1: Create the refresher**

Create `App/Widgets/WidgetSnapshotRefresher.swift`:

```swift
import Foundation
import WidgetKit
import GSDStore
import GSDSnapshot

/// Writes the Today's Focus snapshot whenever the task set changes, coalescing bursts
/// (a bulk pull/import emits many changes) into one write + timeline reload (spec §6).
@MainActor
final class WidgetSnapshotRefresher {
    private let store: TaskStore
    private let snapshotStore: WidgetSnapshotStore
    private let now: () -> Date
    private let debounce: Duration
    private var debounceTask: _Concurrency.Task<Void, Never>?

    init(store: TaskStore,
         snapshotStore: WidgetSnapshotStore = WidgetSnapshotStore(),
         now: @escaping () -> Date = { Date() },
         debounce: Duration = .seconds(1)) {
        self.store = store
        self.snapshotStore = snapshotStore
        self.now = now
        self.debounce = debounce
    }

    /// Write an initial snapshot immediately so a freshly added widget has data.
    func start() { writeNow() }

    /// Coalesce a burst of task changes into a single delayed write + reload.
    func schedule() {
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: self.debounce)
            if _Concurrency.Task.isCancelled { return }
            self.writeNow()
        }
    }

    private func writeNow() {
        let snapshot = WidgetSnapshotBuilder.todaysFocus(from: store.tasks, now: now())
        do { try snapshotStore.write(snapshot) } catch { return }  // no container ⇒ skip, never crash
        WidgetCenter.shared.reloadAllTimelines()
    }
}
```

- [ ] **Step 2: Add the GSDSnapshot dependency to the app target**

In `project.yml`, under `targets:` → `GSD:` → `dependencies:`, add a new entry alongside the existing GSDModel/GSDStore/GSDSync products:

```yaml
      - package: GSDKit
        product: GSDSnapshot
```

- [ ] **Step 3: Wire the refresher into `GSDApp`**

In `App/GSDApp.swift`:

(a) Add the import near the top (after `import GSDSync`):

```swift
import GSDSnapshot
```

(b) Add a stored property next to the others (after `@State private var coordinator: SyncCoordinator`):

```swift
    @State private var widgetRefresher: WidgetSnapshotRefresher
```

(c) In `init()`, immediately after the existing `store.onMutation = { coordinator.scheduleDebouncedPush() }` line, create the refresher and wire the hook:

```swift
        let widgetRefresher = WidgetSnapshotRefresher(store: store)
        _widgetRefresher = State(initialValue: widgetRefresher)
        store.onTasksChanged = { widgetRefresher.schedule() }
```

(d) In `body`'s `.task { … }` modifier, add `widgetRefresher.start()` right after `store.start()`:

```swift
                .task {
                    store.start()
                    widgetRefresher.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                    coordinator.start(trigger: .launch)
                }
```

- [ ] **Step 4: Regenerate and build the app**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Widgets/WidgetSnapshotRefresher.swift App/GSDApp.swift project.yml GSD.xcodeproj
git commit -m "feat(6a): WidgetSnapshotRefresher writes snapshot on task changes"
```

---

## Task 8: `GSDWidgets` extension target + widget code

The widget extension: a new app-extension target (GRDB-free), embedded in the app. Reads the snapshot, renders Today's Focus, deep-links via `gsd://focus`.

> **Note:** the widget's `Info.plist` `NSExtension` dict is declared in `project.yml` (XcodeGen generates `Widgets/Info.plist` from it). The entitlements file is a real source file.

**Files:**
- Modify: `project.yml` (add `GSDWidgets` target + embed it in `GSD`)
- Create: `Widgets/GSDWidgets.entitlements`
- Create: `Widgets/GSDWidgetBundle.swift`
- Create: `Widgets/TodaysFocusEntry.swift`
- Create: `Widgets/TodaysFocusProvider.swift`
- Create: `Widgets/TodaysFocusView.swift`
- Create: `Widgets/TodaysFocusWidget.swift`

- [ ] **Step 1: Create the entitlements file**

Create `Widgets/GSDWidgets.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.dev.vinny.gsd</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2: Create the timeline entry**

Create `Widgets/TodaysFocusEntry.swift`:

```swift
import WidgetKit
import GSDSnapshot

struct TodaysFocusEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}
```

- [ ] **Step 3: Create the timeline provider**

Create `Widgets/TodaysFocusProvider.swift`:

```swift
import WidgetKit
import GSDSnapshot

/// Reads the precomputed snapshot. One entry, `.never` policy — `today-focus` has no time
/// component, so the app's `reloadAllTimelines()` is the sole refresh driver (spec §8).
struct TodaysFocusProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> TodaysFocusEntry {
        TodaysFocusEntry(date: Date(), snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodaysFocusEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : (store.read() ?? .empty)
        completion(TodaysFocusEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodaysFocusEntry>) -> Void) {
        let entry = TodaysFocusEntry(date: Date(), snapshot: store.read() ?? .empty)
        completion(Timeline(entries: [entry], policy: .never))
    }
}
```

- [ ] **Step 4: Create the view**

Create `Widgets/TodaysFocusView.swift`:

```swift
import SwiftUI
import WidgetKit
import GSDSnapshot

struct TodaysFocusView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodaysFocusEntry

    private var visibleCount: Int { family == .systemSmall ? 3 : 5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Today's Focus", systemImage: "target")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if entry.snapshot.tasks.isEmpty {
                Spacer(minLength: 0)
                Text("All clear")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ForEach(entry.snapshot.tasks.prefix(visibleCount)) { task in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "circle").font(.caption2).foregroundStyle(.tint)
                        Text(task.title).font(.caption).lineLimit(1)
                    }
                }
                if entry.snapshot.totalCount > visibleCount {
                    Text("+\(entry.snapshot.totalCount - visibleCount) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(DeepLinkRoute.focus.url)
    }
}
```

- [ ] **Step 5: Create the widget configuration**

Create `Widgets/TodaysFocusWidget.swift`:

```swift
import WidgetKit
import SwiftUI

struct TodaysFocusWidget: Widget {
    let kind = "TodaysFocusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodaysFocusProvider()) { entry in
            TodaysFocusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today's Focus")
        .description("Your urgent and important tasks.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
```

- [ ] **Step 6: Create the widget bundle (`@main`)**

Create `Widgets/GSDWidgetBundle.swift`:

```swift
import WidgetKit
import SwiftUI

@main
struct GSDWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodaysFocusWidget()
    }
}
```

- [ ] **Step 7: Add the extension target + embed in `project.yml`**

In `project.yml`, add a new target under `targets:` (sibling of `GSD`):

```yaml
  GSDWidgets:
    type: app-extension
    platform: iOS
    sources:
      - Widgets
    info:
      path: Widgets/Info.plist
      properties:
        CFBundleDisplayName: GSD Widgets
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.vinny.gsd.widgets
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "NO"
        CODE_SIGN_ENTITLEMENTS: Widgets/GSDWidgets.entitlements
        CODE_SIGN_STYLE: Automatic
    dependencies:
      - package: GSDKit
        product: GSDModel
      - package: GSDKit
        product: GSDSnapshot
```

Then add the embed dependency to the `GSD` target's `dependencies:` list (so the extension ships inside the app):

```yaml
      - target: GSDWidgets
        embed: true
```

- [ ] **Step 8: Regenerate and build (app + embedded extension)**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`. (The `GSD` scheme builds `GSDWidgets` as an embedded dependency.)

If the build reports a missing-Info.plist for the extension, confirm `xcodegen generate` created `Widgets/Info.plist` (it is generated from the `info.properties` above).

- [ ] **Step 9: Commit**

```bash
git add project.yml GSD.xcodeproj Widgets/
git commit -m "feat(6a): GSDWidgets extension + Today's Focus widget"
```

---

## Task 9: Deep-link app wiring — `CFBundleURLTypes` + `ContentView.onOpenURL`

Register the `gsd` scheme and route `gsd://focus` to the Matrix, reusing the existing `navigate(to:)`.

> **Reminder:** `CFBundleURLTypes` goes in `project.yml` (it generates `App/Info.plist`). Do NOT hand-edit `App/Info.plist`.

**Files:**
- Modify: `project.yml` (add `CFBundleURLTypes` to the `GSD` target's `info.properties`)
- Modify: `App/ContentView.swift`

- [ ] **Step 1: Register the URL scheme in `project.yml`**

In `project.yml`, under `targets:` → `GSD:` → `info:` → `properties:`, add:

```yaml
        CFBundleURLTypes:
          - CFBundleURLName: dev.vinny.gsd
            CFBundleURLSchemes:
              - gsd
```

- [ ] **Step 2: Add the import and the handler to `ContentView`**

In `App/ContentView.swift`:

(a) Add the import (after `import GSDStore`):

```swift
import GSDSnapshot
```

(b) Attach `.onOpenURL` in `body` — add it after the `.sheet(item: $paletteEditor) { … }` line:

```swift
            .onOpenURL { handleDeepLink($0) }
```

(c) Add the handler method (place it just above the existing `private func navigate(to dest:)`):

```swift
    private func handleDeepLink(_ url: URL) {
        guard let route = DeepLinkParser.route(from: url) else { return }  // ignores gsd://oauth-callback
        switch route {
        case .focus: navigate(to: .matrix)   // the Matrix's Q1 quadrant IS today's focus
        }
    }
```

- [ ] **Step 3: Regenerate and build**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Verify the scheme landed in the generated plist**

Run: `plutil -extract CFBundleURLTypes xml1 -o - App/Info.plist`
Expected: output containing `gsd` under `CFBundleURLSchemes`. (Confirms the project.yml-driven generation worked.)

- [ ] **Step 5: Commit**

```bash
git add project.yml App/Info.plist App/ContentView.swift GSD.xcodeproj
git commit -m "feat(6a): register gsd:// scheme + route gsd://focus to Matrix"
```

---

## Task 10: Integration — build both simulators, `simctl openurl`, full test suite

Final verification gate before the device live-gate. No new code — proves the whole slice works end-to-end in the simulator.

**Files:** none (verification only).

- [ ] **Step 1: Run the full package test suite**

Run: `cd GSDKit && swift test 2>&1 | tail -15`
Expected: all tests pass (the prior ~400 plus the new GSDSnapshot/GSDStore tests). No failures.

- [ ] **Step 2: Build for iPhone 17 Pro**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Build for iPad Pro 13-inch (M5)**

Run:
```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Install + launch on the booted iPhone simulator**

Find the built `.app` and install it (the `-showBuildSettings` line gets the products dir):

```bash
APP=$(xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d"/"n}')
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted dev.vinny.gsd
```
Expected: the app installs and launches without crashing.

- [ ] **Step 5: Verify the deep link routes to the Matrix**

Run:
```bash
xcrun simctl openurl booted "gsd://focus"
```
Expected: the running app foregrounds on the **Matrix** tab. (`gsd://oauth-callback` would be a no-op — not tested here, covered by the unit test and the device OAuth gate.)

- [ ] **Step 6: Manually verify the widget (simulator GUI)**

In the booted simulator: long-press the home screen → **＋** → search "GSD" / "Today's Focus" → add the `systemSmall` and `systemMedium` widgets. Verify each renders the urgent+important task rows (or "All clear" if none). Tap the widget → the app foregrounds on the Matrix.

Note any discrepancy (empty when tasks exist, stale data, no routing) as a blocker — do not mark complete.

- [ ] **Step 7: Update the project memory**

Append Phase 6a status to `/Users/vinnycarpenter/.claude/projects/-Users-vinnycarpenter-Projects-gsd-iosapp/memory/gsd-ios-project-state.md` (mark 6a IMPLEMENTED, simulator-verified, awaiting device live-gate + portal registration of `dev.vinny.gsd.widgets`).

- [ ] **Step 8: Final commit (if any uncommitted artifacts)**

```bash
git add -A
git commit -m "chore(6a): integration verification complete" || echo "nothing to commit"
```

---

## Device Live-Gate (post-merge, user-performed)

Not part of the simulator implementation; these require the Apple Developer portal and a physical device:

1. Register App ID `dev.vinny.gsd.widgets` in the portal; add the **App Groups** capability (`group.dev.vinny.gsd`) to it; regenerate provisioning. `DEVELOPMENT_TEAM=52HVJ3VDSM` stays committed.
2. Install on device; add the widget to the home screen; confirm it shows real tasks and updates after an in-app edit.
3. **OAuth coexistence gate:** sign out and complete a real OAuth sign-in — confirm it still completes end-to-end now that `gsd://` is registered (the parser ignores `gsd://oauth-callback`).

After the live-gate passes: merge (fast-forward/linear) + tag `phase-6a-widget-foundation` + push + delete branch + update memory.

---

## Self-Review

**Spec coverage:**
- §3.1 module graph → Tasks 2 (GSDSnapshot), 8 (GSDWidgets). §4.1 AppGroup → Task 1. §4.2 contract (WidgetSnapshot/Store/Builder/DeepLink) → Tasks 2–5. §4.3 onTasksChanged → Task 6. §4.4 refresher → Task 7. §4.5 extension → Task 8. §4.6 deep-link wiring → Task 9. §4.7 project.yml/Package.swift → Tasks 2/7/8/9. §5 query → Task 3. §6 debounce → Task 7. §7 OAuth gate → Tasks 5 (parser), 9 (scheme), 10 + live-gate. §8 timeline → Task 8. §9 error handling → Tasks 4 (nil/throws), 7 (skip-on-no-container). §10 testing → Tasks 1–6 + 10. §11 build/portal → Task 10 + live-gate. All sections covered.

**Placeholder scan:** No TBD/TODO; every code step has complete code; no "similar to Task N".

**Type consistency:** `AppGroup.id`, `WidgetSnapshot(generatedAt:tasks:totalCount:)`, `WidgetTask(id:title:dueDate:)`, `WidgetSnapshot.empty`/`.sample`, `WidgetSnapshotBuilder.todaysFocus(from:now:calendar:limit:)`, `WidgetSnapshotStore(containerURL:)`/`.fileName`/`.read()`/`.write(_:)`, `WidgetSnapshotError.noContainer`, `DeepLinkRoute.focus`/`.url`, `DeepLinkParser.route(from:)`, `TaskStore.onTasksChanged`, `WidgetSnapshotRefresher(store:)`/`.start()`/`.schedule()` — names match across all tasks and the widget/app consumers.
