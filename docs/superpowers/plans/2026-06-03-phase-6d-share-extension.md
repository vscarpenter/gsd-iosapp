# Phase 6d — Share Extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let users capture a task into GSD from any app's Share Sheet (a shared URL or text) via a small compose sheet, without opening the app, by dropping a durable "pending capture" file in the App Group that the app materializes through the existing `TaskStore.create` path on next launch/foreground.

**Architecture:** The extension is a separate, GRDB-free process. It writes one JSON file per capture to `<AppGroup>/share-outbox/<id>.json`. On launch and foreground the app drains the outbox through a single-flight, unit-tested `ShareInbox` that calls `TaskStore.create` — reusing the one write path that already does validation + sync-enqueue + reminders + UI/widget refresh. No new module: the four new types live in the existing `GSDSnapshot` target (already the GRDB-free app↔extension contract).

**Tech Stack:** Swift 6 / SwiftPM (`GSDSnapshot` target), Swift Testing (`swift test`), SwiftUI + UIKit (`UIHostingController`) for the extension UI, XcodeGen (`project.yml`) for the new `app-extension` target, `xcodebuild` + `simctl` for build/smoke verification.

**Execution note:** Like Phase 6a, execute **inline** (sequential chain over shared files — `project.yml`, `GSD.xcodeproj`, `App/GSDApp.swift`; NOT subagent-driven). Tasks 1–4 are pure package work verified by `swift test`. Task 5 is app wiring verified by `xcodebuild`. Task 6 is the extension target verified by `xcodebuild`. Task 7 is the integration + simctl smoke gate.

**Reference signatures (already in the codebase — do not redefine):**
- `AppGroup.id == "group.dev.vinny.gsd"` (`GSDModel/AppGroup.swift`).
- `IDGenerator.generate(size: IDGenerator.Size.task) -> String` (task size = 21).
- `URLSanitizer.sanitize(_ candidate: String) -> String?` (http/https only, no creds, `< 2048`).
- `FieldLimits`: `titleRange = 1...80`, `descriptionMax = 600`, `tagLengthRange = 1...30`, `maxTags = 20`.
- `TaskValidator.validate(_ task: Task) throws` — the always-valid invariant target.
- `Task.init(id:title:description:urgent:important:createdAt:updatedAt:tags:...)` — all other params default.
- `Quadrant`: `CaseIterable` string enum; Q4 default = `.notUrgentNotImportant`; `.title`, `.isUrgent`, `.isImportant`, `init(urgent:important:)`.
- `TaskStore.create(_ task: Task) async throws` — re-stamps `createdAt`/`updatedAt`, validates, upserts, enqueues `.create`, schedules reminders.
- App-glue pattern to mirror: `App/Widgets/WidgetSnapshotRefresher.swift` + its wiring in `App/GSDApp.swift`.
- `project.yml` template to mirror: the `GSDWidgets` `app-extension` target.

---

## Task Sequence Overview

1. `SharedCapture` — the Codable cross-process payload (GSDSnapshot).
2. `ShareOutboxStore` — App-Group directory IO (write / pending / remove).
3. `SharedCaptureBuilder` — pure, always-valid `Task` builder.
4. `ShareInbox` — single-flight drain loop (closure-injected `create`).
5. App wiring — construct `ShareInbox` in `GSDApp`; drain on launch (after `store.start()`) + foreground.
6. `GSDShareExtension` target — `project.yml` + entitlements + `ShareViewController` + `ShareComposeView`.
7. Integration — regenerate, build both sims, full `swift test`, simctl smoke (share URL from Safari + text from Notes).

---

## Task 1: `SharedCapture` — the cross-process payload

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/SharedCapture.swift`
- Test: `GSDKit/Tests/GSDSnapshotTests/SharedCaptureTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GSDKit/Tests/GSDSnapshotTests/SharedCaptureTests.swift`:

```swift
import Testing
import Foundation
import GSDSnapshot

struct SharedCaptureTests {
    private var sample: SharedCapture {
        SharedCapture(title: "Read this", urls: ["https://example.com"],
                      urgent: false, important: false, tags: ["read", "later"],
                      capturedAt: Date(timeIntervalSince1970: 42))
    }

    @Test func roundTrips() throws {
        let data = try JSONEncoder().encode(sample)
        let decoded = try JSONDecoder().decode(SharedCapture.self, from: data)
        #expect(decoded == sample)
    }

    @Test func encodesAllFields() throws {
        let json = try JSONEncoder().encode(sample)
        let object = try JSONSerialization.jsonObject(with: json) as? [String: Any]
        #expect(object?["title"] as? String == "Read this")
        #expect(object?["urls"] as? [String] == ["https://example.com"])
        #expect(object?["urgent"] as? Bool == false)
        #expect(object?["tags"] as? [String] == ["read", "later"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter SharedCaptureTests`
Expected: FAIL — `cannot find 'SharedCapture' in scope` (or `no such type`).

- [ ] **Step 3: Write minimal implementation**

Create `GSDKit/Sources/GSDSnapshot/SharedCapture.swift`:

```swift
import Foundation

/// The cross-process payload the Share Extension writes and the app ingests (spec §3, §4.1).
/// Raw user input — `urls`/`title`/`tags` are sanitized, clamped, and normalized on ingest by
/// `SharedCaptureBuilder`, never here.
public struct SharedCapture: Codable, Sendable, Equatable {
    public var title: String          // user-edited; clamped on ingest
    public var urls: [String]         // raw shared URLs; sanitized on ingest
    public var urgent: Bool
    public var important: Bool
    public var tags: [String]         // split from the comma field; normalized on ingest
    public var capturedAt: Date

    public init(title: String, urls: [String], urgent: Bool, important: Bool,
                tags: [String], capturedAt: Date) {
        self.title = title
        self.urls = urls
        self.urgent = urgent
        self.important = important
        self.tags = tags
        self.capturedAt = capturedAt
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter SharedCaptureTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSnapshot/SharedCapture.swift GSDKit/Tests/GSDSnapshotTests/SharedCaptureTests.swift
git commit -m "feat(6d): SharedCapture cross-process payload"
```

---

## Task 2: `ShareOutboxStore` — App-Group directory IO

The store owns the `<AppGroup>/share-outbox/` directory: one file per capture, written atomically by the extension, listed + removed by the app. Corrupt files are skipped **and deleted** so they can't accumulate.

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/ShareOutboxStore.swift`
- Test: `GSDKit/Tests/GSDSnapshotTests/ShareOutboxStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GSDKit/Tests/GSDSnapshotTests/ShareOutboxStoreTests.swift`:

```swift
import Testing
import Foundation
import GSDSnapshot

struct ShareOutboxStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func capture(_ title: String, at t: TimeInterval) -> SharedCapture {
        SharedCapture(title: title, urls: [], urgent: false, important: false,
                      tags: [], capturedAt: Date(timeIntervalSince1970: t))
    }

    @Test func writeThenPendingReturnsCapture() throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let pending = store.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.capture.title == "a")
    }

    @Test func pendingSortedByCapturedAt() throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("late", at: 200))
        try store.write(capture("early", at: 100))
        #expect(store.pending().map(\.capture.title) == ["early", "late"])
    }

    @Test func removeDeletesOneFile() throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        try store.write(capture("b", at: 2))
        let first = store.pending()[0]
        store.remove(id: first.id)
        let remaining = store.pending()
        #expect(remaining.count == 1)
        #expect(remaining.first?.capture.title == "b")
    }

    @Test func corruptFileSkippedAndDeleted() throws {
        let dir = try tempDir()
        let store = ShareOutboxStore(directoryURL: dir)
        try store.write(capture("good", at: 1))
        let badURL = dir.appendingPathComponent("share-outbox/zzz.json")
        try Data("not json".utf8).write(to: badURL)
        let pending = store.pending()
        #expect(pending.map(\.capture.title) == ["good"])     // corrupt skipped
        #expect(!FileManager.default.fileExists(atPath: badURL.path))  // and deleted
    }

    @Test func writeThrowsWithoutContainer() {
        let store = ShareOutboxStore(directoryURL: nil)
        #expect(throws: ShareOutboxError.self) {
            try store.write(SharedCapture(title: "x", urls: [], urgent: false,
                                          important: false, tags: [], capturedAt: Date()))
        }
    }

    @Test func pendingReturnsEmptyWithoutContainer() {
        #expect(ShareOutboxStore(directoryURL: nil).pending().isEmpty)
    }
}
```

> **Note on the corrupt-file test:** the test writes the bad file into the `share-outbox/` subdirectory the store creates on its first `write`. The injected `directoryURL` is the *container*; the store appends `share-outbox/` itself (matching production, where `directoryURL` is the App-Group container and the store owns the subdirectory).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter ShareOutboxStoreTests`
Expected: FAIL — `cannot find 'ShareOutboxStore' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `GSDKit/Sources/GSDSnapshot/ShareOutboxStore.swift`:

```swift
import Foundation
import GSDModel

/// The App-Group "outbox" the Share Extension writes and the app drains (spec §3, §6).
/// One file per capture so the extension's write and the app's drain never race on the same
/// file, and multiple shares before the app opens each survive.
public struct ShareOutboxStore: Sendable {
    public static let directoryName = "share-outbox"
    private let directoryURL: URL?

    /// Production: resolves `<AppGroup>/share-outbox/` (pure Foundation; GRDB-free).
    public init(appGroupID: String = AppGroup.id, fileManager: FileManager = .default) {
        self.directoryURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Test seam: inject a temp *container* directory (the store appends `share-outbox/`),
    /// or nil to simulate a missing App-Group container.
    public init(directoryURL: URL?) {
        self.directoryURL = directoryURL?.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Atomic write to a unique filename; creates the directory on first use.
    public func write(_ capture: SharedCapture) throws {
        guard let dir = directoryURL else { throw ShareOutboxError.noContainer }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = IDGenerator.generate(size: IDGenerator.Size.task)
        let url = dir.appendingPathComponent("\(id).json")
        let data = try JSONEncoder().encode(capture)
        try data.write(to: url, options: .atomic)
    }

    /// All captures, sorted by `capturedAt`. Unreadable/corrupt files are skipped AND deleted
    /// (unrecoverable; prevents accumulation). Missing container ⇒ empty.
    public func pending() -> [(id: String, capture: SharedCapture)] {
        guard let dir = directoryURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var result: [(id: String, capture: SharedCapture)] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let capture = try? JSONDecoder().decode(SharedCapture.self, from: data) else {
                try? FileManager.default.removeItem(at: url)   // corrupt → skip + delete
                continue
            }
            let id = String(name.dropLast(".json".count))
            result.append((id: id, capture: capture))
        }
        return result.sorted { $0.capture.capturedAt < $1.capture.capturedAt }
    }

    /// Delete one capture's file after a successful ingest. Best-effort (already-gone ⇒ no-op).
    public func remove(id: String) {
        guard let dir = directoryURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }
}

public enum ShareOutboxError: Error { case noContainer }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter ShareOutboxStoreTests`
Expected: PASS (all six tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSnapshot/ShareOutboxStore.swift GSDKit/Tests/GSDSnapshotTests/ShareOutboxStoreTests.swift
git commit -m "feat(6d): ShareOutboxStore App-Group directory IO"
```

---

## Task 3: `SharedCaptureBuilder` — pure, always-valid `Task` builder

A **total function**: every `SharedCapture` (even adversarial) maps to a `Task` that passes `TaskValidator.validate`. This is what lets the drain treat any non-transient failure as impossible (spec §5, §6).

**Decision — tags are DROPPED, not truncated (resolves spec §5 "normalize ≤30"):** the comma field is free-form, so a tag is trimmed + lowercased, then **dropped if it falls outside `tagLengthRange` (1...30)** after trimming (empty or too-long). Truncating a 35-char tag to 30 would invent a tag the user never typed and risks collisions; dropping is honest and keeps the invariant trivially true. Then dedupe (preserve order) and cap at `maxTags` (20).

**Title:** trim; empty → `"Review link below"` (matches `CaptureParser`'s `String(localized:)` fallback); else clamp to `titleRange.upperBound` (80) via `prefix`.
**Description:** sanitize each URL with `URLSanitizer.sanitize`, drop nils, join valid with `\n`, clamp to `descriptionMax` (600).

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/SharedCaptureBuilder.swift`
- Test: `GSDKit/Tests/GSDSnapshotTests/SharedCaptureBuilderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GSDKit/Tests/GSDSnapshotTests/SharedCaptureBuilderTests.swift`:

```swift
import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct SharedCaptureBuilderTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func capture(title: String = "Title", urls: [String] = [],
                         urgent: Bool = false, important: Bool = false,
                         tags: [String] = []) -> SharedCapture {
        SharedCapture(title: title, urls: urls, urgent: urgent, important: important,
                      tags: tags, capturedAt: now)
    }

    @Test func usesIdAndNow() {
        let task = SharedCaptureBuilder.task(from: capture(), id: "ID-1", now: now)
        #expect(task.id == "ID-1")
        #expect(task.createdAt == now)
        #expect(task.updatedAt == now)
    }

    @Test func clampsTitleTo80() {
        let long = String(repeating: "x", count: 200)
        let task = SharedCaptureBuilder.task(from: capture(title: long), id: "i", now: now)
        #expect(task.title.count == 80)
    }

    @Test func emptyTitleFallsBack() {
        let task = SharedCaptureBuilder.task(from: capture(title: "   "), id: "i", now: now)
        #expect(task.title == "Review link below")
    }

    @Test func quadrantFlagsPassThrough() {
        let task = SharedCaptureBuilder.task(
            from: capture(urgent: true, important: true), id: "i", now: now)
        #expect(task.urgent && task.important)
        #expect(task.quadrant == .urgentImportant)
    }

    @Test func defaultIsEliminate() {
        let task = SharedCaptureBuilder.task(from: capture(), id: "i", now: now)
        #expect(task.quadrant == .notUrgentNotImportant)
    }

    @Test func sanitizesUrlsIntoDescription() {
        let task = SharedCaptureBuilder.task(
            from: capture(urls: ["https://ok.com", "javascript:alert(1)", "http://two.com"]),
            id: "i", now: now)
        #expect(task.description == "https://ok.com\nhttp://two.com")  // unsafe dropped
    }

    @Test func clampsDescriptionTo600() {
        // A single very long (but http) URL is < 2048 so it survives sanitize; clamp to 600.
        let longURL = "https://e.com/" + String(repeating: "a", count: 1000)
        let task = SharedCaptureBuilder.task(from: capture(urls: [longURL]), id: "i", now: now)
        #expect(task.description.count == 600)
    }

    @Test func normalizesTags() {
        let task = SharedCaptureBuilder.task(
            from: capture(tags: [" Read ", "READ", "later", "", "x"]), id: "i", now: now)
        #expect(task.tags == ["read", "later", "x"])   // trimmed, lowercased, deduped, empty dropped
    }

    @Test func dropsOverlongTagsAndCapsAt20() {
        let overlong = String(repeating: "t", count: 31)
        let many = (0..<25).map { "tag\($0)" }
        let task = SharedCaptureBuilder.task(
            from: capture(tags: [overlong] + many), id: "i", now: now)
        #expect(!task.tags.contains(overlong))   // > 30 dropped
        #expect(task.tags.count == 20)            // capped
    }

    @Test func alwaysProducesValidTask() throws {
        // Adversarial: huge title, too many over-long tags, unsafe URL, empty everything.
        let adversarial = [
            capture(title: String(repeating: "z", count: 5000),
                    urls: ["not a url", "ftp://x", "https://ok.com"],
                    tags: (0..<50).map { _ in String(repeating: "q", count: 40) }),
            capture(title: "", urls: [], tags: []),
            capture(title: "ok", urls: ["javascript:alert(1)"], tags: ["", "  "]),
        ]
        for c in adversarial {
            let task = SharedCaptureBuilder.task(from: c, id: "i", now: now)
            #expect(throws: Never.self) { try TaskValidator.validate(task) }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter SharedCaptureBuilderTests`
Expected: FAIL — `cannot find 'SharedCaptureBuilder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `GSDKit/Sources/GSDSnapshot/SharedCaptureBuilder.swift`:

```swift
import Foundation
import GSDModel

/// Pure: maps any `SharedCapture` to a `Task` guaranteed to pass `TaskValidator.validate`
/// (spec §5). Free-form share input is sanitized, clamped, and normalized here so the drain
/// can treat validation failure as impossible.
public enum SharedCaptureBuilder {
    public static func task(from capture: SharedCapture, id: String, now: Date) -> Task {
        Task(
            id: id,
            title: clampedTitle(capture.title),
            description: description(from: capture.urls),
            urgent: capture.urgent,
            important: capture.important,
            createdAt: now,
            updatedAt: now,
            tags: normalizedTags(capture.tags)
        )
    }

    private static func clampedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Review link below") }
        return String(trimmed.prefix(FieldLimits.titleRange.upperBound))   // clamp to 80
    }

    private static func description(from urls: [String]) -> String {
        let valid = urls.compactMap { URLSanitizer.sanitize($0) }
        let joined = valid.joined(separator: "\n")
        return joined.count > FieldLimits.descriptionMax
            ? String(joined.prefix(FieldLimits.descriptionMax))            // clamp to 600
            : joined
    }

    private static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard FieldLimits.tagLengthRange.contains(t.count) else { continue }  // drop empty / >30
            guard seen.insert(t).inserted else { continue }                       // dedupe, keep order
            result.append(t)
            if result.count == FieldLimits.maxTags { break }                      // cap at 20
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter SharedCaptureBuilderTests`
Expected: PASS (all ten tests, including `alwaysProducesValidTask`).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDSnapshot/SharedCaptureBuilder.swift GSDKit/Tests/GSDSnapshotTests/SharedCaptureBuilderTests.swift
git commit -m "feat(6d): SharedCaptureBuilder — always-valid Task from share input"
```

---

## Task 4: `ShareInbox` — single-flight drain loop

The testable core of the handoff. `@MainActor`, closure-injected `create` (GRDB-free, so a fake `create` drives the tests). Single-flight: launch + foreground fire near-simultaneously at cold start; the `isDraining` guard is set **synchronously** (no `await` between the `guard` and the set) so an overlapping call returns immediately — without it, two drains both read the same file before either removes it → duplicate task (spec §4.1, §6).

**Files:**
- Create: `GSDKit/Sources/GSDSnapshot/ShareInbox.swift`
- Test: `GSDKit/Tests/GSDSnapshotTests/ShareInboxTests.swift`

- [ ] **Step 1: Write the failing test**

Create `GSDKit/Tests/GSDSnapshotTests/ShareInboxTests.swift`:

```swift
import Testing
import Foundation
import GSDModel
import GSDSnapshot

@MainActor
struct ShareInboxTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func capture(_ title: String, at t: TimeInterval) -> SharedCapture {
        SharedCapture(title: title, urls: [], urgent: false, important: false,
                      tags: [], capturedAt: Date(timeIntervalSince1970: t))
    }

    @Test func successfulCreateRemovesFile() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)
        var created: [String] = []
        await inbox.drain { task in created.append(task.title) }
        #expect(created == ["a"])
        #expect(store.pending().isEmpty)        // file removed after success
    }

    @Test func transientFailureKeepsFile() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)
        struct Boom: Error {}
        await inbox.drain { _ in throw Boom() }
        #expect(store.pending().count == 1)     // kept for retry
    }

    @Test func processesAllPendingInOrder() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("late", at: 200))
        try store.write(capture("early", at: 100))
        let inbox = ShareInbox(store: store)
        var created: [String] = []
        await inbox.drain { task in created.append(task.title) }
        #expect(created == ["early", "late"])
        #expect(store.pending().isEmpty)
    }

    /// Single-flight: gate the first drain's `create` on a continuation so it is mid-flight;
    /// start a SECOND drain while it is suspended — that one must hit `guard !isDraining` and
    /// return without creating; then resume the first. Exactly one create must happen.
    @Test func singleFlightPreventsDoubleCreate() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)

        var createCount = 0
        var gate: CheckedContinuation<Void, Never>?
        let gateReady = AsyncStream<Void>.makeStream()

        // First drain: suspends inside `create` until we resume the gate.
        let first = _Concurrency.Task { @MainActor in
            await inbox.drain { _ in
                createCount += 1
                gateReady.continuation.yield()       // signal: we are now mid-create
                await withCheckedContinuation { gate = $0 }
            }
        }

        // Wait until the first drain is provably mid-create.
        var it = gateReady.stream.makeAsyncIterator()
        _ = await it.next()

        // Second drain while the first is suspended → must no-op (single-flight).
        await inbox.drain { _ in createCount += 1 }
        #expect(createCount == 1)                    // the overlapping drain did nothing

        gate?.resume()                               // let the first drain finish
        await first.value
        #expect(createCount == 1)                    // still exactly one
        #expect(store.pending().isEmpty)             // and the file is now removed
    }
}
```

> **Why this orchestration matters (advisor note):** everything here is `@MainActor`, so there is no true parallelism — the overlap can only occur at the `await create` suspension point. A test that just calls `drain` twice sequentially would pass even if single-flight were broken (the first drain finishes and removes the file before the second runs). Gating `create` on a continuation is the only way to actually hold the first drain open across a second call.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter ShareInboxTests`
Expected: FAIL — `cannot find 'ShareInbox' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `GSDKit/Sources/GSDSnapshot/ShareInbox.swift`:

```swift
import Foundation
import GSDModel

/// Drains the share outbox through the app's `create` path (spec §3, §4.1). `@MainActor` and
/// single-flight so the launch + foreground drains that fire near-simultaneously at cold start
/// don't double-create. GRDB-free: the app injects `TaskStore.create` as the `create` closure.
@MainActor
public final class ShareInbox {
    private let store: ShareOutboxStore
    private let now: () -> Date
    private let newID: () -> String
    private var isDraining = false

    public init(store: ShareOutboxStore,
                now: @escaping () -> Date = { Date() },
                newID: @escaping () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) }) {
        self.store = store
        self.now = now
        self.newID = newID
    }

    /// Single-flight (`isDraining` set synchronously before any `await`). Each pending capture
    /// is built into a valid `Task` and handed to `create`; the file is removed only after
    /// `create` succeeds. A transient `create` throw keeps the file for the next drain.
    public func drain(create: (Task) async throws -> Void) async {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        for item in store.pending() {
            let task = SharedCaptureBuilder.task(from: item.capture, id: newID(), now: now())
            do {
                try await create(task)
                store.remove(id: item.id)        // only after success
            } catch {
                continue                          // transient failure → keep file, retry next drain
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter ShareInboxTests`
Expected: PASS (all four tests, including `singleFlightPreventsDoubleCreate`).

- [ ] **Step 5: Run the full GSDSnapshot suite + commit**

Run: `cd GSDKit && swift test --filter GSDSnapshotTests`
Expected: PASS (the new SharedCapture/ShareOutboxStore/SharedCaptureBuilder/ShareInbox tests plus the existing Widget/DeepLink tests).

```bash
git add GSDKit/Sources/GSDSnapshot/ShareInbox.swift GSDKit/Tests/GSDSnapshotTests/ShareInboxTests.swift
git commit -m "feat(6d): ShareInbox single-flight outbox drain"
```

---

## Task 5: App wiring — construct `ShareInbox`, drain on launch + foreground

Mirror the 6a `WidgetSnapshotRefresher` wiring: construct the inbox in `GSDApp.init`, drain it in the root `.task` (launch) and on `scenePhase == .active` (foreground). The substance is the tested `ShareInbox`; this is trivial glue.

> **No unit test:** the app has no test target (same as the 6a refresher). `ShareInbox` is fully covered in Task 4; this task is verified by the build here and the simctl smoke in Task 7.

> **Sequencing (advisor note):** the launch drain goes **after** `store.start()` so the GRDB observer is live when the materialized task lands — the same reasoning as the 6a launch path. `store.create` upserts directly, and the now-running observer propagates it to the UI + fires `onTasksChanged` (widget refresh).

**Files:**
- Modify: `App/GSDApp.swift`

- [ ] **Step 1: Add the `@State` property**

In `App/GSDApp.swift`, after the `widgetRefresher` state declaration (around line 13):

```swift
    @State private var widgetRefresher: WidgetSnapshotRefresher
    @State private var shareInbox: ShareInbox          // ADD THIS LINE
```

- [ ] **Step 2: Construct the inbox in `init`**

In `init()`, immediately after the widget-refresher wiring block (the `store.onTasksChanged = { widgetRefresher.schedule() }` line, around line 70) and before `_session = State(...)`:

```swift
        store.onTasksChanged = { widgetRefresher.schedule() }
        // Share Extension inbox (Phase 6d): drains the App-Group outbox through the SAME
        // create() path on launch + foreground. Trivial glue; the logic is the tested ShareInbox.
        let shareInbox = ShareInbox(store: ShareOutboxStore())
        _shareInbox = State(initialValue: shareInbox)
        _session = State(initialValue: SessionStore(auth: authService, tokenStore: tokenStore, coordinator: coordinator))
```

- [ ] **Step 3: Drain on launch (in the root `.task`)**

In `body`, the `.task` modifier, add the drain right after `store.start()`:

```swift
                .task {
                    store.start()
                    await shareInbox.drain { try await store.create($0) }   // ADD THIS LINE
                    widgetRefresher.start()
                    try? await store.runAutoArchiveSweep()
                    await store.refreshBadge()
                    coordinator.start(trigger: .launch)
                }
```

- [ ] **Step 4: Drain on foreground (in the `scenePhase` `.active` case)**

In the `.onChange(of: scenePhase)` handler, the `.active` case:

```swift
                    case .active:
                        coordinator.enteredForeground()
                        _Concurrency.Task { await store.refreshBadge() }
                        _Concurrency.Task { await shareInbox.drain { try await store.create($0) } }   // ADD THIS LINE
```

- [ ] **Step 5: Regenerate and build the app**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add App/GSDApp.swift GSD.xcodeproj
git commit -m "feat(6d): drain share outbox on launch + foreground via ShareInbox"
```

---

## Task 6: `GSDShareExtension` target — compose UI + outbox write

The extension: a new GRDB-free `app-extension` target embedded in the app. It reads the shared URL/text from the `NSItemProvider`, prefills a SwiftUI compose sheet, and on **Add** writes a `SharedCapture` to the outbox.

> **`NSExtensionActivationRule` is make-or-break (spec §11).** It compiles fine when wrong and then GSD is silently absent from the share sheet. The exact keys (verified): `NSExtensionActivationSupportsWebURLWithMaxCount: 1` and `NSExtensionActivationSupportsText: true`, nested under `NSExtensionAttributes → NSExtensionActivationRule` (the dict form, **not** the `TRUEPREDICATE` string). `NSExtensionPrincipalClass` must be `ShareViewController`, which the `@objc(ShareViewController)` annotation exposes to the ObjC runtime without a module prefix. This is verified only by the Task 7 smoke (share both a URL and text).

> **Info.plist is generated by XcodeGen** from `info.properties` in `project.yml` (same as the Widgets target) — do not hand-write `ShareExtension/Info.plist`; `xcodegen generate` creates it.

**Files:**
- Modify: `project.yml` (add `GSDShareExtension` target + embed it in `GSD`)
- Create: `ShareExtension/GSDShareExtension.entitlements`
- Create: `ShareExtension/ShareViewController.swift`
- Create: `ShareExtension/ShareComposeView.swift`

- [ ] **Step 1: Add the target to `project.yml`**

In `project.yml`, add to the `GSD` target's `dependencies` (after the existing `GSDWidgets` embed):

```yaml
      - target: GSDWidgets
        embed: true
      - target: GSDShareExtension     # ADD
        embed: true                   # ADD
```

Then add the new target under `targets:` (after the `GSDWidgets` target block):

```yaml
  GSDShareExtension:
    type: app-extension
    platform: iOS
    sources:
      - ShareExtension
    info:
      path: ShareExtension/Info.plist
      properties:
        CFBundleDisplayName: GSD
        CFBundleShortVersionString: "$(MARKETING_VERSION)"
        CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"
        NSExtension:
          NSExtensionPointIdentifier: com.apple.share-services
          NSExtensionPrincipalClass: ShareViewController
          NSExtensionAttributes:
            NSExtensionActivationRule:
              NSExtensionActivationSupportsWebURLWithMaxCount: 1
              NSExtensionActivationSupportsText: true
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.vinny.gsd.share
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "NO"
        CODE_SIGN_ENTITLEMENTS: ShareExtension/GSDShareExtension.entitlements
        CODE_SIGN_STYLE: Automatic
    dependencies:
      - package: GSDKit
        product: GSDModel
      - package: GSDKit
        product: GSDSnapshot
```

- [ ] **Step 2: Create the entitlements file**

Create `ShareExtension/GSDShareExtension.entitlements`:

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

- [ ] **Step 3: Create the principal `ShareViewController`**

Create `ShareExtension/ShareViewController.swift`:

```swift
import UIKit
import SwiftUI
import UniformTypeIdentifiers
import GSDModel
import GSDSnapshot

/// The share-extension entry point (NSExtensionPrincipalClass). Extracts the shared URL or text
/// from the NSItemProvider, then hosts the SwiftUI compose sheet. GRDB-free: it only writes a
/// SharedCapture to the App-Group outbox; the app materializes it later (spec §4.2).
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let outbox = ShareOutboxStore()

    override func viewDidLoad() {
        super.viewDidLoad()
        extractSharedItem { [weak self] prefilledTitle, urls in
            self?.presentCompose(prefilledTitle: prefilledTitle, urls: urls)
        }
    }

    /// Prefer a web-URL attachment; fall back to plain text; else present empty (user types).
    /// Both loads are async and may complete off the main thread — hop back before presenting.
    private func extractSharedItem(completion: @escaping (String, [String]) -> Void) {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let providers = item.attachments, !providers.isEmpty else {
            DispatchQueue.main.async { completion("", []) }
            return
        }
        let pageTitle = item.attributedContentText?.string ?? ""

        if let urlProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            urlProvider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { value, _ in
                let urlString = (value as? URL)?.absoluteString ?? ""
                DispatchQueue.main.async {
                    completion(pageTitle.isEmpty ? urlString : pageTitle,
                               urlString.isEmpty ? [] : [urlString])
                }
            }
        } else if let textProvider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            textProvider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { value, _ in
                let text = (value as? String) ?? ""
                DispatchQueue.main.async { completion(text, []) }
            }
        } else {
            DispatchQueue.main.async { completion(pageTitle, []) }
        }
    }

    private func presentCompose(prefilledTitle: String, urls: [String]) {
        let composeView = ShareComposeView(
            initialTitle: prefilledTitle,
            urls: urls,
            save: { [weak self] capture in try self?.outbox.write(capture) },
            onComplete: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) },
            onCancel: { [weak self] in
                self?.extensionContext?.cancelRequest(
                    withError: NSError(domain: "dev.vinny.gsd.share", code: 0))
            }
        )
        let host = UIHostingController(rootView: composeView)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }
}
```

- [ ] **Step 4: Create the SwiftUI compose sheet**

Create `ShareExtension/ShareComposeView.swift`:

```swift
import SwiftUI
import GSDModel
import GSDSnapshot

/// The compose sheet: editable title, quadrant picker (default Eliminate/Q4), comma tags, the
/// captured URL(s) shown read-only, Add / Cancel (spec §4.2). On Add it builds a SharedCapture
/// and calls `save`; a write failure surfaces inline (no container) — the sheet does not dismiss.
struct ShareComposeView: View {
    let urls: [String]
    let save: (SharedCapture) throws -> Void
    let onComplete: () -> Void
    let onCancel: () -> Void

    @State private var title: String
    @State private var quadrant: Quadrant = .notUrgentNotImportant   // default Eliminate/Q4
    @State private var tagsText = ""
    @State private var errorMessage: String?

    init(initialTitle: String, urls: [String],
         save: @escaping (SharedCapture) throws -> Void,
         onComplete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.urls = urls
        self.save = save
        self.onComplete = onComplete
        self.onCancel = onCancel
        _title = State(initialValue: initialTitle)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Task") {
                    TextField("Title", text: $title, axis: .vertical)
                }
                Section("Quadrant") {
                    Picker("Quadrant", selection: $quadrant) {
                        ForEach(Quadrant.allCases, id: \.self) { q in
                            Text(q.title).tag(q)
                        }
                    }
                }
                Section("Tags") {
                    TextField("comma, separated, tags", text: $tagsText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                if !urls.isEmpty {
                    Section("Link") {
                        ForEach(urls, id: \.self) { url in
                            Text(url).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add to GSD")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add)
                }
            }
        }
    }

    private func add() {
        let capture = SharedCapture(
            title: title,
            urls: urls,
            urgent: quadrant.isUrgent,
            important: quadrant.isImportant,
            tags: tagsText.split(separator: ",").map(String.init),   // raw; builder normalizes
            capturedAt: Date()
        )
        do {
            try save(capture)
            onComplete()
        } catch {
            errorMessage = String(localized: "Couldn't save to GSD. Please try again.")
        }
    }
}
```

- [ ] **Step 5: Regenerate and build (the `GSD` scheme builds the embedded extension)**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -8
```
Expected: `** BUILD SUCCEEDED **`. If it reports a missing Info.plist for the extension, confirm `xcodegen generate` created `ShareExtension/Info.plist` (generated from `info.properties`).

- [ ] **Step 6: Verify the activation rule landed in the generated plist**

Run: `plutil -extract NSExtension.NSExtensionAttributes.NSExtensionActivationRule xml1 -o - ShareExtension/Info.plist`
Expected: output containing `NSExtensionActivationSupportsWebURLWithMaxCount` (integer `1`) and `NSExtensionActivationSupportsText` (`<true/>`). This is the make-or-break config; confirm it before the smoke.

- [ ] **Step 7: Commit**

```bash
git add project.yml ShareExtension GSD.xcodeproj
git commit -m "feat(6d): GSDShareExtension target — compose sheet + outbox write"
```

---

## Task 7: Integration — full test suite, both sims, share-sheet smoke

The gate. Full `swift test`, build both simulators, then the make-or-break smoke: GSD appears in the share sheet for **both** a URL (Safari) and **text** (Notes), and a shared item materializes as a task when the app opens.

**Files:** none (verification only).

- [ ] **Step 1: Full package test suite**

Run: `cd GSDKit && swift test 2>&1 | tail -15`
Expected: all tests pass — the prior ~419 plus the ~22 new GSDSnapshot tests from Tasks 1–4 (SharedCapture 2 · ShareOutboxStore 6 · SharedCaptureBuilder 10 · ShareInbox 4). No failures.

- [ ] **Step 2: Build iPhone 17 Pro**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Build iPad Pro 13" (M5)**

Run:
```bash
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Install + launch the app (crash check)**

Run:
```bash
APP=$(xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR / {d=$2} / FULL_PRODUCT_NAME / {n=$2} END {print d"/"n}')
xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted dev.vinny.gsd
```
Expected: the app installs and launches without crashing (the embedded extension installs with it).

- [ ] **Step 5: Smoke the URL share path (Safari) — manual in the booted sim**

`simctl` cannot script the share sheet, so this step is observe-by-eye in the booted simulator:

1. `xcrun simctl openurl booted "https://www.apple.com"` (opens Safari).
2. In Safari, tap the Share button → confirm **GSD** appears in the share sheet (this proves `NSExtensionActivationSupportsWebURLWithMaxCount`).
3. Tap GSD → the compose sheet appears with the page title prefilled and the URL shown read-only.
4. Leave the quadrant at **Eliminate**, optionally type `read, later` in tags, tap **Add** → the sheet dismisses.
5. Open GSD (`xcrun simctl launch booted dev.vinny.gsd`) → confirm the task appears in the **Eliminate** quadrant with the sanitized URL in its description and the `read`/`later` tags.

Expected: all five succeed. If GSD is absent from the share sheet, the activation rule is wrong (re-check Task 6 Step 6).

- [ ] **Step 6: Smoke the text share path (Notes) — manual in the booted sim**

1. Open Notes in the booted sim, type a line of text, select it, tap Share.
2. Confirm **GSD** appears (this proves `NSExtensionActivationSupportsText` — gated independently of URL).
3. Tap GSD → compose sheet with the text prefilled as the title, no Link section.
4. Tap **Add**, open GSD → confirm the task appears (Eliminate quadrant, no description).

Expected: all four succeed. The URL and text paths are gated by separate activation keys, so both must be smoked (spec §8, §11).

- [ ] **Step 7: Final commit (if anything changed during integration) + tag readiness**

If Steps 1–6 surfaced no code changes, nothing to commit — the branch is ready for the device live-gate. If a fix was needed, commit it:

```bash
git add -A
git commit -m "fix(6d): <what the smoke surfaced>"
```

Do **not** merge or tag yet — the device live-gate (below) gates the merge.

---

## Device Live-Gate (post-merge readiness, user-performed)

Sim-verified work is complete after Task 7; these need a real device + the Apple portal (spec §9):

1. Register App ID `dev.vinny.gsd.share` in the Apple Developer portal + add the **App Groups** capability (`group.dev.vinny.gsd`) + provisioning. `DEVELOPMENT_TEAM=52HVJ3VDSM` stays committed.
2. On a real device: share a URL from a real app (Safari/News) and text from a real app → confirm GSD appears, the compose sheet works, **Add** dismisses.
3. Open GSD → confirm the task appears, and on the next sync it **pushes to the web app** (the outbox handoff reuses `TaskStore.create` → enqueue `.create`).
4. Confirm sign-in / sync are unaffected by the new extension.

Then: merge (ff / linear) + tag `phase-6d-share-extension` + push + delete the branch. Update the project-state memory.

---

## Self-Review

Checked the plan against the approved spec (`docs/specs/2026-06-03-phase-6d-share-extension.md`):

**Spec coverage:**
- §2 scope — `GSDShareExtension` target (Task 6) · `SharedCapture`/`ShareOutboxStore`/`SharedCaptureBuilder`/`ShareInbox` (Tasks 1–4) · drain on launch + foreground (Task 5). ✓
- §3 architecture (outbox file → drain → `TaskStore.create`) — Tasks 4 (drain) + 5 (wiring to `store.create`). ✓
- §4.1 the four GSDSnapshot types with the exact signatures — Tasks 1–4. ✓
- §4.2 extension (activation rule, principal class, `NSItemProvider` URL/text, compose sheet, Add/Cancel, inline write-failure) — Task 6. ✓
- §4.3 app wiring after `store.start()` + foreground — Task 5. ✓
- §4.4 `project.yml` target + embed, no `Package.swift` change — Task 6 Step 1. ✓
- §5 capture/build rules (default Q4, title clamp 80 + empty fallback, URL sanitize → description clamp 600, tag normalize ≤20×≤30) — Task 3 with explicit **drop-not-truncate** decision. ✓
- §6 outbox semantics (one-file-per-capture, single-flight, corrupt skip+delete, success-then-remove, transient keep, accepted crash-dup risk) — Tasks 2 + 4. ✓
- §8 testing list — every bullet maps to a named test: Codable round-trip (T1), outbox write/pending/remove/sorted/corrupt/no-container (T2), builder clamp/fallback/sanitize/desc-clamp/tags/quadrant/**always-valid adversarial** (T3), inbox success/transient/corrupt-skip/**single-flight** (T4); build + dual-path share smoke (T7). ✓
- §9 build-vs-portal boundary — Task 7 (sim) + Device Live-Gate (portal). ✓

**Placeholder scan:** no "TBD"/"handle errors"/"similar to" — every code step shows complete code; every run step shows the command + expected output.

**Type consistency:** `ShareOutboxStore` uses `share-outbox` dir + `IDGenerator.Size.task` filenames consistently across `write`/`pending`/`remove`; `SharedCaptureBuilder.task(from:id:now:)` signature identical in T3 source, T3 tests, and T4's `drain`; `ShareInbox.drain(create:)` closure type `(Task) async throws -> Void` matches `store.create` in T5; `Quadrant.notUrgentNotImportant`/`.title`/`.isUrgent`/`.isImportant` match the real enum; `FieldLimits` constants (`titleRange`/`descriptionMax`/`tagLengthRange`/`maxTags`) used by name, never as magic numbers.

---

## Notes for the executor

- **Run order is sequential** over shared files (`project.yml`, `GSD.xcodeproj`, `App/GSDApp.swift`). Execute inline, not subagent-driven (like 6a).
- After each `swift test` task, the GRDB/app build is untouched — only Tasks 5–7 need `xcodegen generate` + `xcodebuild`.
- The one accepted risk (crash between `create` and `remove` re-ingests one duplicate) is documented in spec §6; an idempotency key is deferred (YAGNI). Do not add one.
- If `xcodebuild` can't find the `iPad Pro 13-inch (M5)` destination name, list available sims with `xcrun simctl list devices available` and use the closest iPad Pro 13" match.



