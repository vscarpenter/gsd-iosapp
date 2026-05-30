# Phase 0 — Foundations Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the Xcode project, the `GSDKit` package (pure `GSDModel` + GRDB-backed `GSDStore`), the `Task` domain model with all embedded types, web-compatible ID generation, validation, and a versioned SQLite store with a `TaskRepository` — all under test via `swift test`.

**Architecture:** A layered local Swift package. `GSDModel` holds pure value types and pure functions with zero dependencies (fast `swift test`, no simulator). `GSDStore` adds GRDB persistence: a `TaskRecord` row that maps bidirectionally to the pure `Task`, a `v1` migration, and a `TaskRepository` exposing async CRUD plus `ValueObservation` streams. The iOS app target is a buildable shell this phase; real UI arrives in Phase 1.

**Tech Stack:** Swift 6, SwiftUI, GRDB 7 (SQLite), Swift Testing (`@Test`), XcodeGen (project generation), iOS 26 deployment target.

**Reference:** Increment spec `docs/specs/2026-05-30-phase-0-2-foundations-core-depth.md`; product spec `2026-05-30-native-ios-app-design.md` (§5 data model, Appendix B limits).

---

## File Structure

```
gsd-iosapp/
├─ project.yml                      # XcodeGen: app target, package ref, entitlement
├─ App/
│   ├─ GSDApp.swift                 # @main app entry (shell this phase)
│   ├─ ContentView.swift            # placeholder UI (replaced in Phase 1)
│   └─ GSD.entitlements             # App Group group.dev.vinny.gsd
├─ GSDKit/
│   ├─ Package.swift                # GSDModel, GSDStore, test targets; GRDB dep
│   └─ Sources/
│       ├─ GSDModel/
│       │   ├─ Quadrant.swift       # quadrant id + derivation + display metadata
│       │   ├─ RecurrenceType.swift # none/daily/weekly/monthly
│       │   ├─ Subtask.swift        # embedded value type
│       │   ├─ TimeEntry.swift      # embedded value type
│       │   ├─ Task.swift           # core entity (all §5.1 fields)
│       │   ├─ IDGenerator.swift    # nanoid-compatible, injectable RNG
│       │   └─ Validation.swift     # Appendix-B limits
│       └─ GSDStore/
│           ├─ StoreLocation.swift  # storeURL provider (App Group / fallback)
│           ├─ AppDatabase.swift    # DatabaseQueue + migrator wiring
│           ├─ Migrations.swift     # registerV1 (tasks table)
│           ├─ TaskRecord.swift     # GRDB row + Task <-> TaskRecord mapper
│           └─ TaskRepository.swift # async CRUD + ValueObservation
└─ GSDKit/Tests/
    ├─ GSDModelTests/               # one file per unit under test
    └─ GSDStoreTests/
```

Each file has one responsibility. `GSDModel` files never import GRDB. `GSDStore` files never contain business rules (those live in `GSDModel`); they only persist and observe.

---

## Task 1: Project scaffold (XcodeGen + GSDKit package skeleton)

**Files:**
- Create: `project.yml`
- Create: `GSDKit/Package.swift`
- Create: `GSDKit/Sources/GSDModel/Placeholder.swift` (temporary, deleted in Task 2)
- Create: `GSDKit/Sources/GSDStore/Placeholder.swift` (temporary, deleted in Task 7)
- Create: `App/GSDApp.swift`, `App/ContentView.swift`, `App/GSD.entitlements`

- [ ] **Step 1: Install XcodeGen if absent**

Run: `which xcodegen || brew install xcodegen`
Expected: a path to `xcodegen`, or a successful Homebrew install.

- [ ] **Step 2: Write `GSDKit/Package.swift`**

> **Note:** `swift-tools-version` must be **6.2** or higher — the `.v26` platform enum is unavailable in 6.0/6.1. (Verified by compile-probe against the installed toolchain.)

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "GSDKit",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "GSDModel", targets: ["GSDModel"]),
        .library(name: "GSDStore", targets: ["GSDStore"]),
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
        .testTarget(name: "GSDModelTests", dependencies: ["GSDModel"]),
        .testTarget(name: "GSDStoreTests", dependencies: ["GSDStore"]),
    ]
)
```

- [ ] **Step 3: Add temporary placeholders so the package compiles**

`GSDKit/Sources/GSDModel/Placeholder.swift`:
```swift
// Temporary: removed in Task 2 once real types exist.
enum GSDModelPlaceholder {}
```

`GSDKit/Sources/GSDStore/Placeholder.swift`:
```swift
// Temporary: removed in Task 7 once real persistence exists.
enum GSDStorePlaceholder {}
```

- [ ] **Step 4: Write the app shell**

`App/GSDApp.swift`:
```swift
import SwiftUI

@main
struct GSDApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

`App/ContentView.swift`:
```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("GSD")
            .font(.system(.largeTitle, design: .serif))
            .padding()
    }
}

#Preview { ContentView() }
```

`App/GSD.entitlements`:
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

- [ ] **Step 5: Write `project.yml`**

```yaml
name: GSD
options:
  bundleIdPrefix: dev.vinny
  deploymentTarget:
    iOS: "26.0"
  createIntermediateGroups: true
packages:
  GSDKit:
    path: GSDKit
targets:
  GSD:
    type: application
    platform: iOS
    sources:
      - App
    dependencies:
      - package: GSDKit
        product: GSDModel
      - package: GSDKit
        product: GSDStore
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: dev.vinny.gsd
        MARKETING_VERSION: "0.1.0"
        CURRENT_PROJECT_VERSION: "1"
        SWIFT_VERSION: "6.0"
        GENERATE_INFOPLIST_FILE: "YES"
        CODE_SIGN_ENTITLEMENTS: App/GSD.entitlements
        CODE_SIGN_STYLE: Automatic
        # DEVELOPMENT_TEAM: <your Team ID>   # set before device builds; simulator works without it
```

- [ ] **Step 6: Generate the project and verify the package builds**

Run: `cd GSDKit && swift build && cd ..`
Expected: `Build complete!` (GRDB resolves and compiles).

Run: `xcodegen generate`
Expected: `Created project at GSD.xcodeproj`.

Run: `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add project.yml App GSDKit/Package.swift GSDKit/Package.resolved GSDKit/Sources GSD.xcodeproj
git commit -m "chore: scaffold Xcode project and GSDKit package"
```

> The `.xcodeproj` is generated, but committing it keeps the repo buildable without requiring every checkout to run XcodeGen. `project.yml` remains the source of truth — regenerate after changing it; do not hand-edit the `.xcodeproj`.

---

## Task 2: Quadrant & RecurrenceType enums

**Files:**
- Create: `GSDKit/Sources/GSDModel/Quadrant.swift`
- Create: `GSDKit/Sources/GSDModel/RecurrenceType.swift`
- Delete: `GSDKit/Sources/GSDModel/Placeholder.swift`
- Test: `GSDKit/Tests/GSDModelTests/QuadrantTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/QuadrantTests.swift`:
```swift
import Testing
@testable import GSDModel

struct QuadrantTests {
    @Test func urgentImportant_isDoFirst() {
        #expect(Quadrant(urgent: true, important: true) == .urgentImportant)
        #expect(Quadrant.urgentImportant.title == "Do First")
        #expect(Quadrant.urgentImportant.rawValue == "urgent-important")
    }

    @Test func derivationCoversAllFourCombinations() {
        #expect(Quadrant(urgent: false, important: true) == .notUrgentImportant)
        #expect(Quadrant(urgent: true, important: false) == .urgentNotImportant)
        #expect(Quadrant(urgent: false, important: false) == .notUrgentNotImportant)
    }

    @Test func canonicalOrderIsQ1ThroughQ4() {
        #expect(Quadrant.allCases == [
            .urgentImportant, .notUrgentImportant,
            .urgentNotImportant, .notUrgentNotImportant,
        ])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter QuadrantTests`
Expected: FAIL — `cannot find 'Quadrant' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/Quadrant.swift`:
```swift
/// The four Eisenhower quadrants. Declaration order is the canonical
/// display/iteration order Q1→Q4 (product spec §5.8).
public enum Quadrant: String, Codable, Sendable, CaseIterable {
    case urgentImportant = "urgent-important"               // Q1 Do First
    case notUrgentImportant = "not-urgent-important"        // Q2 Schedule
    case urgentNotImportant = "urgent-not-important"        // Q3 Delegate
    case notUrgentNotImportant = "not-urgent-not-important" // Q4 Eliminate

    /// Derives the quadrant from the two axes. The single source of truth —
    /// the persisted column is always written from this, never set directly.
    public init(urgent: Bool, important: Bool) {
        switch (urgent, important) {
        case (true, true): self = .urgentImportant
        case (false, true): self = .notUrgentImportant
        case (true, false): self = .urgentNotImportant
        case (false, false): self = .notUrgentNotImportant
        }
    }

    public var title: String {
        switch self {
        case .urgentImportant: "Do First"
        case .notUrgentImportant: "Schedule"
        case .urgentNotImportant: "Delegate"
        case .notUrgentNotImportant: "Eliminate"
        }
    }
}
```

`GSDKit/Sources/GSDModel/RecurrenceType.swift`:
```swift
/// Recurrence kinds. There is intentionally no "yearly" (product spec §5.1, App. A).
public enum RecurrenceType: String, Codable, Sendable, CaseIterable {
    case none, daily, weekly, monthly
}
```

Then delete the placeholder: `rm GSDKit/Sources/GSDModel/Placeholder.swift`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter QuadrantTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/Quadrant.swift GSDKit/Sources/GSDModel/RecurrenceType.swift GSDKit/Tests/GSDModelTests/QuadrantTests.swift
git rm GSDKit/Sources/GSDModel/Placeholder.swift
git commit -m "feat: add Quadrant derivation and RecurrenceType"
```

---

## Task 3: Subtask & TimeEntry embedded value types

**Files:**
- Create: `GSDKit/Sources/GSDModel/Subtask.swift`
- Create: `GSDKit/Sources/GSDModel/TimeEntry.swift`
- Test: `GSDKit/Tests/GSDModelTests/EmbeddedTypesTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/EmbeddedTypesTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct EmbeddedTypesTests {
    @Test func subtaskEncodesAndDecodesRoundTrip() throws {
        let subtask = Subtask(id: "abcd", title: "Draft outline", completed: false)
        let data = try JSONEncoder().encode(subtask)
        let decoded = try JSONDecoder().decode(Subtask.self, from: data)
        #expect(decoded == subtask)
    }

    @Test func timeEntryAllowsNilEndedAtAndNotes() throws {
        let entry = TimeEntry(id: "ab123456", startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: nil, notes: nil)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TimeEntry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.endedAt == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter EmbeddedTypesTests`
Expected: FAIL — `cannot find 'Subtask' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/Subtask.swift`:
```swift
/// A checklist item embedded in a Task (product spec §5.2). Max 50 per task.
public struct Subtask: Codable, Sendable, Identifiable, Equatable {
    public var id: String        // >= 4 chars
    public var title: String     // 1–100 chars
    public var completed: Bool

    public init(id: String, title: String, completed: Bool = false) {
        self.id = id
        self.title = title
        self.completed = completed
    }
}
```

`GSDKit/Sources/GSDModel/TimeEntry.swift`:
```swift
import Foundation

/// A single tracked interval embedded in a Task (product spec §5.3).
/// `endedAt` is nil while the timer runs. Max 1000 per task.
public struct TimeEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String          // nanoid length 8
    public var startedAt: Date
    public var endedAt: Date?      // nil while running
    public var notes: String?      // 0–200 chars

    public init(id: String, startedAt: Date, endedAt: Date? = nil, notes: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.notes = notes
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter EmbeddedTypesTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/Subtask.swift GSDKit/Sources/GSDModel/TimeEntry.swift GSDKit/Tests/GSDModelTests/EmbeddedTypesTests.swift
git commit -m "feat: add Subtask and TimeEntry embedded types"
```

---

## Task 4: Task core entity

**Files:**
- Create: `GSDKit/Sources/GSDModel/Task.swift`
- Test: `GSDKit/Tests/GSDModelTests/TaskTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/TaskTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct TaskTests {
    @Test func quadrantIsDerivedFromFlagsAndNeverStoredDirectly() {
        var task = Task(id: "t1", title: "Ship", urgent: true, important: true,
                        createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0))
        #expect(task.quadrant == .urgentImportant)
        task.urgent = false
        #expect(task.quadrant == .notUrgentImportant) // recomputed, no drift
    }

    @Test func defaultsMatchSpec() {
        let task = Task(id: "t2", title: "Read", urgent: false, important: false,
                        createdAt: Date(timeIntervalSince1970: 0),
                        updatedAt: Date(timeIntervalSince1970: 0))
        #expect(task.completed == false)
        #expect(task.recurrence == .none)
        #expect(task.tags.isEmpty)
        #expect(task.subtasks.isEmpty)
        #expect(task.dependencies.isEmpty)
        #expect(task.notificationEnabled == true)
        #expect(task.notificationSent == false)
        #expect(task.timeEntries.isEmpty)
    }

    @Test func encodesAndDecodesRoundTrip() throws {
        let task = Task(id: "t3", title: "Plan", urgent: false, important: true,
                        createdAt: Date(timeIntervalSince1970: 100),
                        updatedAt: Date(timeIntervalSince1970: 200),
                        tags: ["home"], dependencies: ["t1"])
        let data = try JSONEncoder().encode(task)
        let decoded = try JSONDecoder().decode(Task.self, from: data)
        #expect(decoded == task)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter TaskTests`
Expected: FAIL — `cannot find 'Task' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/Task.swift`:
```swift
import Foundation

/// The core entity (product spec §5.1). All fields are stored except
/// `quadrant`, which is derived from `urgent`/`important` so it can never drift.
public struct Task: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var description: String
    public var urgent: Bool
    public var important: Bool
    public var completed: Bool
    public var completedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var dueDate: Date?
    public var recurrence: RecurrenceType
    public var tags: [String]
    public var subtasks: [Subtask]
    public var dependencies: [String]
    public var parentTaskId: String?
    public var notifyBefore: Int?
    public var notificationEnabled: Bool
    public var notificationSent: Bool          // device-local
    public var lastNotificationAt: Date?       // device-local
    public var snoozedUntil: Date?             // device-local
    public var estimatedMinutes: Int?
    public var timeSpent: Int?                 // calculated from timeEntries
    public var timeEntries: [TimeEntry]

    /// Derived, never persisted into this struct — the store column is written
    /// from this value (product spec §5.8).
    public var quadrant: Quadrant { Quadrant(urgent: urgent, important: important) }

    public init(
        id: String,
        title: String,
        description: String = "",
        urgent: Bool,
        important: Bool,
        completed: Bool = false,
        completedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date,
        dueDate: Date? = nil,
        recurrence: RecurrenceType = .none,
        tags: [String] = [],
        subtasks: [Subtask] = [],
        dependencies: [String] = [],
        parentTaskId: String? = nil,
        notifyBefore: Int? = nil,
        notificationEnabled: Bool = true,
        notificationSent: Bool = false,
        lastNotificationAt: Date? = nil,
        snoozedUntil: Date? = nil,
        estimatedMinutes: Int? = nil,
        timeSpent: Int? = nil,
        timeEntries: [TimeEntry] = []
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.urgent = urgent
        self.important = important
        self.completed = completed
        self.completedAt = completedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.dueDate = dueDate
        self.recurrence = recurrence
        self.tags = tags
        self.subtasks = subtasks
        self.dependencies = dependencies
        self.parentTaskId = parentTaskId
        self.notifyBefore = notifyBefore
        self.notificationEnabled = notificationEnabled
        self.notificationSent = notificationSent
        self.lastNotificationAt = lastNotificationAt
        self.snoozedUntil = snoozedUntil
        self.estimatedMinutes = estimatedMinutes
        self.timeSpent = timeSpent
        self.timeEntries = timeEntries
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter TaskTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/Task.swift GSDKit/Tests/GSDModelTests/TaskTests.swift
git commit -m "feat: add Task core entity with derived quadrant"
```

---

## Task 5: IDGenerator (web-compatible nanoid)

**Files:**
- Create: `GSDKit/Sources/GSDModel/IDGenerator.swift`
- Test: `GSDKit/Tests/GSDModelTests/IDGeneratorTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/IDGeneratorTests.swift`:
```swift
import Testing
@testable import GSDModel

/// Deterministic RNG so ID generation is reproducible in tests
/// (coding standards: inject randomness).
struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // xorshift64 — adequate for test determinism, not cryptography.
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

struct IDGeneratorTests {
    @Test func generatesRequestedLength() {
        var rng = SeededRNG(seed: 1)
        #expect(IDGenerator.generate(size: 8, using: &rng).count == 8)
        #expect(IDGenerator.generate(size: 12, using: &rng).count == 12)
    }

    @Test func usesOnlyUrlSafeCharacters() {
        var rng = SeededRNG(seed: 42)
        let id = IDGenerator.generate(size: 64, using: &rng)
        let allowed = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        #expect(id.allSatisfy { allowed.contains($0) })
    }

    @Test func isDeterministicForAGivenSeed() {
        var a = SeededRNG(seed: 7)
        var b = SeededRNG(seed: 7)
        #expect(IDGenerator.generate(size: 21, using: &a) == IDGenerator.generate(size: 21, using: &b))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter IDGeneratorTests`
Expected: FAIL — `cannot find 'IDGenerator' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/IDGenerator.swift`:
```swift
/// URL-safe nanoid-compatible identifiers so records round-trip with the web
/// app and PocketBase (product spec §5). Randomness is injected for testability.
public enum IDGenerator {
    /// nanoid's URL-safe alphabet.
    public static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")

    /// Minimum lengths the rest of the app should use.
    public enum Size {
        public static let task = 21       // web default; spec floor is 4
        public static let timeEntry = 8
        public static let smartView = 12
    }

    public static func generate(size: Int = Size.task, using rng: inout some RandomNumberGenerator) -> String {
        precondition(size >= 1, "id size must be positive")
        var result = ""
        result.reserveCapacity(size)
        for _ in 0..<size {
            let index = Int.random(in: 0..<alphabet.count, using: &rng)
            result.append(alphabet[index])
        }
        return result
    }

    public static func generate(size: Int = Size.task) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(size: size, using: &rng)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter IDGeneratorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/IDGenerator.swift GSDKit/Tests/GSDModelTests/IDGeneratorTests.swift
git commit -m "feat: add web-compatible nanoid IDGenerator"
```

---

## Task 6: Field limits & validation

**Files:**
- Create: `GSDKit/Sources/GSDModel/Validation.swift`
- Test: `GSDKit/Tests/GSDModelTests/ValidationTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/ValidationTests.swift`:
```swift
import Testing
import Foundation
@testable import GSDModel

struct ValidationTests {
    private func makeTask(title: String) -> Task {
        Task(id: "v1", title: title, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func rejectsEmptyTitle() {
        #expect(throws: ValidationError.titleLength) {
            try TaskValidator.validate(makeTask(title: ""))
        }
    }

    @Test func rejectsTitleOver80Chars() {
        #expect(throws: ValidationError.titleLength) {
            try TaskValidator.validate(makeTask(title: String(repeating: "x", count: 81)))
        }
    }

    @Test func acceptsValidTitle() throws {
        try TaskValidator.validate(makeTask(title: "Buy milk"))
    }

    @Test func estimateOfZeroCoercesToUnset() {
        #expect(FieldLimits.normalizedEstimate(0) == nil)
        #expect(FieldLimits.normalizedEstimate(45) == 45)
    }

    @Test func rejectsTooManyTags() {
        var task = makeTask(title: "ok")
        task.tags = (0..<21).map { "tag\($0)" }
        #expect(throws: ValidationError.tooManyTags) {
            try TaskValidator.validate(task)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter ValidationTests`
Expected: FAIL — `cannot find 'TaskValidator' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/Validation.swift`:
```swift
import Foundation

/// Authoritative field limits (product spec §5.1, Appendix B). Named constants,
/// no magic numbers.
public enum FieldLimits {
    public static let titleRange = 1...80
    public static let descriptionMax = 600
    public static let tagLengthRange = 1...30
    public static let maxTags = 20
    public static let subtaskTitleRange = 1...100
    public static let maxSubtasks = 50
    public static let maxDependencies = 50
    public static let timeEntryNoteMax = 200
    public static let maxTimeEntries = 1000
    public static let estimatedMinutesRange = 1...10080   // 1 min – 7 days
    public static let maxSnoozeInterval: TimeInterval = 365 * 24 * 60 * 60

    /// A stored estimate of 0 means "unset" (product spec §5.1).
    public static func normalizedEstimate(_ value: Int?) -> Int? {
        guard let value, value != 0 else { return nil }
        return value
    }
}

public enum ValidationError: Error, Equatable {
    case titleLength
    case descriptionTooLong
    case tagLength
    case tooManyTags
    case subtaskTitleLength
    case tooManySubtasks
    case tooManyDependencies
    case estimateOutOfRange
    case tooManyTimeEntries
}

public enum TaskValidator {
    public static func validate(_ task: Task) throws {
        guard FieldLimits.titleRange.contains(task.title.count) else { throw ValidationError.titleLength }
        guard task.description.count <= FieldLimits.descriptionMax else { throw ValidationError.descriptionTooLong }
        guard task.tags.count <= FieldLimits.maxTags else { throw ValidationError.tooManyTags }
        guard task.tags.allSatisfy({ FieldLimits.tagLengthRange.contains($0.count) }) else { throw ValidationError.tagLength }
        guard task.subtasks.count <= FieldLimits.maxSubtasks else { throw ValidationError.tooManySubtasks }
        guard task.subtasks.allSatisfy({ FieldLimits.subtaskTitleRange.contains($0.title.count) }) else { throw ValidationError.subtaskTitleLength }
        guard task.dependencies.count <= FieldLimits.maxDependencies else { throw ValidationError.tooManyDependencies }
        guard task.timeEntries.count <= FieldLimits.maxTimeEntries else { throw ValidationError.tooManyTimeEntries }
        if let estimate = task.estimatedMinutes, estimate != 0 {
            guard FieldLimits.estimatedMinutesRange.contains(estimate) else { throw ValidationError.estimateOutOfRange }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter ValidationTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/Validation.swift GSDKit/Tests/GSDModelTests/ValidationTests.swift
git commit -m "feat: add field limits and Task validation"
```

---

## Task 7: GRDB store wiring + `v1` migration

**Files:**
- Create: `GSDKit/Sources/GSDStore/StoreLocation.swift`
- Create: `GSDKit/Sources/GSDStore/AppDatabase.swift`
- Create: `GSDKit/Sources/GSDStore/Migrations.swift`
- Delete: `GSDKit/Sources/GSDStore/Placeholder.swift`
- Test: `GSDKit/Tests/GSDStoreTests/MigrationTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDStoreTests/MigrationTests.swift`:
```swift
import Testing
import GRDB
@testable import GSDStore

struct MigrationTests {
    @Test func v1CreatesTasksTableWithFullColumnSet() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.read { d in
            #expect(try d.tableExists("tasks"))
            let columns = Set(try d.columns(in: "tasks").map(\.name))
            // spot-check the spec-critical columns across scalar, JSON, and device-local groups
            for expected in ["id", "quadrant", "tags", "subtasks", "dependencies",
                             "timeEntries", "snoozedUntil", "notificationSent", "updatedAt"] {
                #expect(columns.contains(expected), "missing column \(expected)")
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter MigrationTests`
Expected: FAIL — `cannot find 'AppDatabase' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDStore/StoreLocation.swift`:
```swift
import Foundation

/// Resolves the on-disk database location. Prefers the App Group container so
/// Phase 6 widgets/extensions share one store; falls back to Application Support
/// when the group is unavailable (e.g. a plain simulator run without the
/// entitlement). This is the single place the path is decided (increment spec §3.1).
public enum StoreLocation {
    public static let appGroupID = "group.dev.vinny.gsd"
    public static let databaseFileName = "gsd.sqlite"

    public static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL.appendingPathComponent(databaseFileName)
        }
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent(databaseFileName)
    }
}
```

`GSDKit/Sources/GSDStore/AppDatabase.swift`:
```swift
import Foundation
import GRDB

/// Owns the GRDB writer and applies migrations on init. Construct once and share.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database at the shared store location.
    public static func live() throws -> AppDatabase {
        let url = try StoreLocation.databaseURL()
        return try AppDatabase(try DatabaseQueue(path: url.path))
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }
}
```

`GSDKit/Sources/GSDStore/Migrations.swift`:
```swift
import GRDB

extension AppDatabase {
    /// Explicit, versioned migration sequence (increment spec §3.3). Never rely on
    /// auto-migration. `v1` is the full §5.1 `tasks` table; later phases add v2+.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        registerV1(&migrator)
        return migrator
    }

    static func registerV1(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1") { db in
            try db.create(table: "tasks") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("description", .text).notNull().defaults(to: "")
                t.column("urgent", .boolean).notNull()
                t.column("important", .boolean).notNull()
                t.column("quadrant", .text).notNull().indexed()
                t.column("completed", .boolean).notNull().defaults(to: false).indexed()
                t.column("completedAt", .datetime)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull().indexed()
                t.column("dueDate", .datetime).indexed()
                t.column("recurrence", .text).notNull().defaults(to: "none")
                t.column("tags", .text).notNull().defaults(to: "[]")           // JSON
                t.column("subtasks", .text).notNull().defaults(to: "[]")       // JSON
                t.column("dependencies", .text).notNull().defaults(to: "[]")   // JSON
                t.column("parentTaskId", .text)
                t.column("notifyBefore", .integer)
                t.column("notificationEnabled", .boolean).notNull().defaults(to: true)
                t.column("notificationSent", .boolean).notNull().defaults(to: false)
                t.column("lastNotificationAt", .datetime)
                t.column("snoozedUntil", .datetime)
                t.column("estimatedMinutes", .integer)
                t.column("timeSpent", .integer)
                t.column("timeEntries", .text).notNull().defaults(to: "[]")    // JSON
            }
        }
    }
}
```

Then delete the placeholder: `rm GSDKit/Sources/GSDStore/Placeholder.swift`

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter MigrationTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/StoreLocation.swift GSDKit/Sources/GSDStore/AppDatabase.swift GSDKit/Sources/GSDStore/Migrations.swift GSDKit/Tests/GSDStoreTests/MigrationTests.swift
git rm GSDKit/Sources/GSDStore/Placeholder.swift
git commit -m "feat: add GRDB store wiring and v1 tasks migration"
```

---

## Task 8: TaskRecord + bidirectional mapper

**Files:**
- Create: `GSDKit/Sources/GSDStore/GSDJSON.swift`
- Create: `GSDKit/Sources/GSDStore/TaskRecord.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskRecordTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDStoreTests/TaskRecordTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct TaskRecordTests {
    @Test func roundTripsToDomainIdentity() throws {
        let task = Task(
            id: "rt1", title: "Plan trip", description: "book flights",
            urgent: true, important: true,
            completed: false, completedAt: nil,
            createdAt: Date(timeIntervalSince1970: 1000),
            updatedAt: Date(timeIntervalSince1970: 2000),
            dueDate: Date(timeIntervalSince1970: 3000),
            recurrence: .weekly,
            tags: ["travel", "home"],
            subtasks: [Subtask(id: "s001", title: "passport", completed: true)],
            dependencies: ["dep1", "dep2"],
            estimatedMinutes: 60,
            timeEntries: [TimeEntry(id: "te000001", startedAt: Date(timeIntervalSince1970: 1500),
                                    endedAt: Date(timeIntervalSince1970: 1800), notes: "focus")]
        )
        let record = try TaskRecord(task)
        #expect(record.quadrant == "urgent-important")
        let restored = try record.toDomain()
        #expect(restored == task)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter TaskRecordTests`
Expected: FAIL — `cannot find 'TaskRecord' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDStore/GSDJSON.swift`:
```swift
import Foundation

/// Shared JSON coding for the embedded-collection columns. ISO-8601 dates keep
/// the JSON forward-compatible with the export/wire formats (increment spec §3.3).
enum GSDJSON {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func string<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func value<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }
}
```

`GSDKit/Sources/GSDStore/TaskRecord.swift`:
```swift
import Foundation
import GRDB
import GSDModel

/// GRDB row for a Task. Scalars map directly; embedded collections (`tags`,
/// `subtasks`, `dependencies`, `timeEntries`) are stored as JSON strings to match
/// the web (Dexie) and PocketBase shapes (increment spec §3.3). `quadrant` is
/// persisted (indexed) but always derived from the flags — never set by hand.
struct TaskRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tasks"

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
}

extension TaskRecord {
    init(_ task: Task) throws {
        id = task.id
        title = task.title
        description = task.description
        urgent = task.urgent
        important = task.important
        quadrant = task.quadrant.rawValue
        completed = task.completed
        completedAt = task.completedAt
        createdAt = task.createdAt
        updatedAt = task.updatedAt
        dueDate = task.dueDate
        recurrence = task.recurrence.rawValue
        tags = try GSDJSON.string(task.tags)
        subtasks = try GSDJSON.string(task.subtasks)
        dependencies = try GSDJSON.string(task.dependencies)
        parentTaskId = task.parentTaskId
        notifyBefore = task.notifyBefore
        notificationEnabled = task.notificationEnabled
        notificationSent = task.notificationSent
        lastNotificationAt = task.lastNotificationAt
        snoozedUntil = task.snoozedUntil
        estimatedMinutes = task.estimatedMinutes
        timeSpent = task.timeSpent
        timeEntries = try GSDJSON.string(task.timeEntries)
    }

    func toDomain() throws -> Task {
        Task(
            id: id, title: title, description: description,
            urgent: urgent, important: important,
            completed: completed, completedAt: completedAt,
            createdAt: createdAt, updatedAt: updatedAt, dueDate: dueDate,
            recurrence: RecurrenceType(rawValue: recurrence) ?? .none,
            tags: try GSDJSON.value([String].self, tags),
            subtasks: try GSDJSON.value([Subtask].self, subtasks),
            dependencies: try GSDJSON.value([String].self, dependencies),
            parentTaskId: parentTaskId,
            notifyBefore: notifyBefore,
            notificationEnabled: notificationEnabled,
            notificationSent: notificationSent,
            lastNotificationAt: lastNotificationAt,
            snoozedUntil: snoozedUntil,
            estimatedMinutes: estimatedMinutes,
            timeSpent: timeSpent,
            timeEntries: try GSDJSON.value([TimeEntry].self, timeEntries)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter TaskRecordTests`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/GSDJSON.swift GSDKit/Sources/GSDStore/TaskRecord.swift GSDKit/Tests/GSDStoreTests/TaskRecordTests.swift
git commit -m "feat: add TaskRecord with bidirectional Task mapper"
```

---

## Task 9: TaskRepository (async CRUD + observation + dependency cleanup)

**Files:**
- Create: `GSDKit/Sources/GSDStore/TaskRepository.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskRepositoryTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDStoreTests/TaskRepositoryTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct TaskRepositoryTests {
    private func makeTask(id: String, dependencies: [String] = []) -> Task {
        Task(id: id, title: "T-\(id)", urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
             dependencies: dependencies)
    }

    @Test func upsertThenFetchReturnsTask() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(makeTask(id: "a"))
        #expect(try await repo.fetch(id: "a")?.id == "a")
    }

    @Test func upsertUpdatesExistingRow() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(makeTask(id: "a"))
        var updated = makeTask(id: "a")
        updated.title = "renamed"
        try await repo.upsert(updated)
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.title == "renamed")
    }

    @Test func deleteRemovesIdFromOtherTasksDependencies() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        try await repo.upsert(makeTask(id: "blocker"))
        try await repo.upsert(makeTask(id: "blocked", dependencies: ["blocker"]))
        try await repo.delete(id: "blocker")
        #expect(try await repo.fetch(id: "blocked")?.dependencies.isEmpty == true)
        #expect(try await repo.fetch(id: "blocker") == nil)
    }

    @Test func observeAllEmitsInitialThenOnInsert() async throws {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory())
        var iterator = repo.observeAll().makeAsyncIterator()
        #expect(try await iterator.next()?.isEmpty == true)  // initial snapshot
        try await repo.upsert(makeTask(id: "x"))
        // Drain until the insert is observed — ValueObservation may coalesce emissions.
        var observed = try await iterator.next()
        while observed?.isEmpty == true { observed = try await iterator.next() }
        #expect(observed?.count == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter TaskRepositoryTests`
Expected: FAIL — `cannot find 'GRDBTaskRepository' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDStore/TaskRepository.swift`:
```swift
import Foundation
import GRDB
import GSDModel

/// Async persistence boundary for tasks. Holds NO business rules. The spec rule
/// "every mutation bumps `updatedAt`" (increment spec §3.3, product spec §5.1) is
/// satisfied one layer up: the Phase 1 use-case/store layer stamps `updatedAt`
/// with an injected clock before calling `upsert`, so the repository itself never
/// injects time. `delete` also strips the id from every other task's
/// `dependencies` (product spec §6.8 cleanup-on-delete).
public protocol TaskRepository: Sendable {
    func upsert(_ task: Task) async throws
    func fetchAll() async throws -> [Task]
    func fetch(id: String) async throws -> Task?
    func delete(id: String) async throws
    func observeAll() -> AsyncThrowingStream<[Task], Error>
}

public final class GRDBTaskRepository: TaskRepository {
    private let dbWriter: any DatabaseWriter
    private let observerQueue = DispatchQueue(label: "dev.vinny.gsd.task-observer")

    public init(_ database: AppDatabase) {
        self.dbWriter = database.writer
    }

    public func upsert(_ task: Task) async throws {
        let record = try TaskRecord(task)
        try await dbWriter.write { db in try record.save(db) }
    }

    public func fetchAll() async throws -> [Task] {
        try await dbWriter.read { db in
            try TaskRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
        }
    }

    public func fetch(id: String) async throws -> Task? {
        try await dbWriter.read { db in
            guard let record = try TaskRecord.fetchOne(db, key: id) else { return nil }
            return try record.toDomain()
        }
    }

    public func delete(id: String) async throws {
        try await dbWriter.write { db in
            for var record in try TaskRecord.fetchAll(db) where record.id != id {
                var deps = try GSDJSON.value([String].self, record.dependencies)
                guard deps.contains(id) else { continue }
                deps.removeAll { $0 == id }
                record.dependencies = try GSDJSON.string(deps)
                try record.update(db, columns: ["dependencies"])
            }
            _ = try TaskRecord.deleteOne(db, key: id)
        }
    }

    public func observeAll() -> AsyncThrowingStream<[Task], Error> {
        AsyncThrowingStream { continuation in
            let observation = ValueObservation.tracking { db in
                try TaskRecord.order(Column("updatedAt").desc).fetchAll(db).map { try $0.toDomain() }
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

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter TaskRepositoryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDStore/TaskRepository.swift GSDKit/Tests/GSDStoreTests/TaskRepositoryTests.swift
git commit -m "feat: add TaskRepository with CRUD, observation, dependency cleanup"
```

---

## Task 10: Phase verification & handoff

**Files:** none created — this task verifies the whole phase and confirms the app still builds.

- [ ] **Step 1: Run the full package suite**

Run: `cd GSDKit && swift test`
Expected: PASS — all `GSDModelTests` and `GSDStoreTests` green, in well under a second (no simulator).

- [ ] **Step 2: Confirm the app target still builds and links GRDB transitively**

Run: `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Smoke-launch the shell on the simulator**

Run:
```bash
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' \
  -derivedDataPath .build-app build -quiet
xcrun simctl install booted ".build-app/Build/Products/Debug-iphonesimulator/GSD.app"
xcrun simctl launch booted dev.vinny.gsd
```
Expected: the app launches and shows "GSD" in a serif title. (Screenshot: `xcrun simctl io booted screenshot phase0.png`.)

- [ ] **Step 4: Confirm a clean tree and tag the phase**

Run: `git status -s`
Expected: empty (every task committed).

Run: `git tag phase-0-foundations && git log --oneline | head -12`
Expected: tag created; commit history shows one commit per task.

- [ ] **Step 5: Handoff note for Phase 1**

Phase 1 will build on these exact entry points (stable public API of `GSDKit`):
- `GSDModel`: `Task`, `Subtask`, `TimeEntry`, `Quadrant`, `RecurrenceType`, `IDGenerator`, `FieldLimits`, `TaskValidator`, `ValidationError`.
- `GSDStore`: `AppDatabase.live()` / `.inMemory()`, `TaskRepository` protocol, `GRDBTaskRepository`.
- The `observeAll()` → `@MainActor @Observable` store bridge is **Phase 1's first task** — validate the pattern on the matrix store before replicating it (increment spec §13 risk #4).

---

## Phase 0 — Definition of Done

- [ ] `swift test` passes for `GSDModel` + `GSDStore` with no simulator (spec acceptance **A1**).
- [ ] `v1` migration creates the `tasks` table with the full §5.1 column set, asserted by a test (**A2**).
- [ ] Generated IDs are URL-safe, meet minimum lengths, and are deterministic under a seeded RNG (**A3**).
- [ ] `Task.quadrant` is derived and provably never drifts from the flags.
- [ ] `TaskRecord ↔ Task` round-trips to identity.
- [ ] `TaskRepository` CRUD works; delete cleans dependency references; `observeAll()` emits on change.
- [ ] The iOS app target builds and launches the shell on the simulator.
- [ ] One commit per task; clean working tree; `phase-0-foundations` tag created.

---

## Deferred polish (from Task 1 code review — address at the noted phase, not now)

These are non-blocking findings from the Task 1 review. None affects the simulator-only Phase 0–2 loop; each is recorded here so it resurfaces when it actually matters.

- **Project-level `SWIFT_VERSION` (→ when a 2nd target is added, Phase 6).** `project.yml` sets Swift 6.0 only on the `GSD` target; the project-level config defaults to Swift 5. Add a top-level `settings.base.SWIFT_VERSION: "6.0"` before adding widget/extension targets so they don't silently compile as Swift 5.
- **Shared Xcode scheme (→ when CI is added).** `GSD.xcodeproj/xcshareddata/xcschemes/` is empty; `xcodebuild -scheme GSD` works only because Xcode auto-generates a user-local scheme. Add a `scheme` to `project.yml` for the `GSD` target and commit the emitted shared scheme before wiring CI / fresh-checkout builds.
- **`DEVELOPMENT_TEAM` + App Group provisioning (→ Phase 6, BLOCKING for device builds).** The `group.dev.vinny.gsd` capability cannot be provisioned for a device build without the owner's Apple Team ID. Obtain the Team ID and set `DEVELOPMENT_TEAM` in `project.yml` before any on-device or extension work. Simulator builds are unaffected.
- **`CODE_SIGN_IDENTITY` (cosmetic).** XcodeGen emitted the deprecated `"iPhone Developer"`; switch to `"Apple Development"` on the next `project.yml` pass.
- **App icon asset (→ Phase 1 theming).** `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is set but there is no `Assets.xcassets`, producing a missing-icon build warning. The Phase 1 theming task creates the asset catalog (accent colors + app icon); fold the fix in there.

