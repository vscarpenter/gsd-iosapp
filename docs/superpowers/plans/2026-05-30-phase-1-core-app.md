# Phase 1 — Core Local App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Phase 0 foundation into a runnable, offline matrix app — the capture-shorthand parser, an `@Observable` store over the repository, theming, the adaptive iPhone/iPad matrix, a task editor, and complete/uncomplete with confetti + delete + show-completed.

**Architecture:** SwiftUI app observing a `@MainActor @Observable TaskStore` that bridges `TaskRepository.observeAll()` into `[Task]` and routes mutations back through the repository (stamping `updatedAt` with an injected clock). The one new pure-logic unit — `CaptureParser` (+ `URLSanitizer`) — lives in `GSDModel` and is TDD'd via `swift test`. UI is size-class adaptive: a stacked-quadrant Matrix on iPhone, a 2×2 grid on iPad.

**Tech Stack:** Swift 6, SwiftUI (Observation, `@Observable`), GSDKit (GSDModel + GSDStore from Phase 0), Swift Testing for logic, `xcodebuild` for the app.

**Builds on (Phase 0, all committed on `main`):**
- `GSDModel`: `Task` (full init at `Task.swift`), `Subtask`, `TimeEntry`, `Quadrant(urgent:important:)` + `.title` + raw values + `CaseIterable` (Q1→Q4), `RecurrenceType`, `IDGenerator.generate(size:)` / `IDGenerator.Size.task`, `FieldLimits`, `TaskValidator.validate(_:) throws`, `ValidationError`.
- `GSDStore`: `AppDatabase.live()` / `.inMemory()`, `TaskRepository` protocol (`upsert`/`fetchAll`/`fetch`/`delete`/`observeAll`), `GRDBTaskRepository(_ database:now:)`.

**Reference:** increment spec `docs/specs/2026-05-30-phase-0-2-foundations-core-depth.md` (§5–6); product spec `2026-05-30-native-ios-app-design.md` (§4 navigation, §6.1 matrix, §6.2 capture/parser, §6.3 editor, §6.4 completion, §12.3 accessibility).

---

## Architecture conventions locked by this plan (read first)

1. **`Task` naming convention (resolves the Phase 0 tech-debt note).** `GSDModel.Task` is the domain model. In app code:
   - Use bare `Task` for the model in type positions (`[Task]`, `task: Task`) — it resolves to `GSDModel.Task` because Swift Concurrency's `Task` is generic and needs type args.
   - For concurrency, prefer SwiftUI's `.task { }` view modifier (no `Task` name) for view-lifecycle async.
   - When an explicit task spawn is unavoidable (e.g. the store's observe loop), write **`_Concurrency.Task { }`** — fully qualified. Never write bare `Task { }` in a file that imports `GSDModel`.
2. **Store is the only mutation path.** Views never touch the repository directly. `TaskStore` (one `@MainActor @Observable` object, injected via `.environment`) owns the `[Task]` snapshot and all mutations. Mutations stamp `updatedAt = clock()` (injected `@Sendable () -> Date`, default `Date.init`) so they're testable and the §3.3 invariant holds at the use-case layer.
3. **Pure logic stays in `GSDModel`.** The parser/sanitizer go in `GSDModel` (zero deps, `swift test`). The store and views are app-target only.
4. **Accessibility from the start** (§12.3): Dynamic Type (no fixed point sizes), VoiceOver labels + custom actions on cards, Reduce Motion gates confetti, ≥44pt hit targets, WCAG-AA quadrant accents.
5. **Localizable strings:** wrap user-facing copy in `String(localized:)`; no string concatenation for UI.

---

## File Structure

```
App/
├─ GSDApp.swift                 # @main; builds AppDatabase.live() + TaskStore, injects store
├─ ContentView.swift            # adaptive root: size-class branch (iPhone stack / iPad split)
├─ Theme/
│   ├─ Theme.swift              # AppTheme enum (light/dark/system) + ColorScheme mapping
│   ├─ QuadrantStyle.swift      # Quadrant -> accent Color + SF Symbol + serif font helpers
│   └─ Assets.xcassets/         # quadrant accent colors (light+dark), AppIcon placeholder
├─ Store/
│   ├─ TaskStore.swift          # @MainActor @Observable; observeAll bridge + mutations
│   └─ AppPreferences.swift     # UserDefaults-backed showCompleted + theme (App-Group suite)
├─ Matrix/
│   ├─ MatrixView.swift         # iPhone: stacked quadrant sections + capture bar
│   ├─ MatrixGridView.swift     # iPad: 2×2 grid
│   ├─ QuadrantSection.swift    # one quadrant: header + live counts + task list
│   ├─ TaskCardView.swift       # the row/card (Phase 1 fields)
│   └─ CaptureBar.swift         # capture field + live parse preview + quadrant override
├─ Editor/
│   └─ TaskEditorView.swift     # Phase 1 editor: title, description, quadrant, tags
└─ Effects/
    └─ ConfettiView.swift       # Canvas + TimelineView, Reduce-Motion aware

GSDKit/Sources/GSDModel/
├─ URLSanitizer.swift           # http/https sanitizer (security-sensitive, §6.2)
├─ CaptureParser.swift          # shorthand grammar -> ParsedCapture
└─ (Phase 0 files unchanged)

GSDKit/Tests/GSDModelTests/
├─ URLSanitizerTests.swift
└─ CaptureParserTests.swift
```

Phase 1 editor intentionally exposes only title/description/quadrant/tags. Due date, recurrence, subtasks, dependencies, snooze, time tracking, estimate, and reminders are Phase 2/4 — the editor grows then.

---

## Group A — Capture parser (GSDModel, pure, `swift test`)

### Task A1: URLSanitizer

**Files:**
- Create: `GSDKit/Sources/GSDModel/URLSanitizer.swift`
- Test: `GSDKit/Tests/GSDModelTests/URLSanitizerTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/URLSanitizerTests.swift`:
```swift
import Testing
@testable import GSDModel

struct URLSanitizerTests {
    @Test func acceptsPlainHttpsURL() {
        #expect(URLSanitizer.sanitize("https://example.com/path") == "https://example.com/path")
    }

    @Test func acceptsHttpURL() {
        #expect(URLSanitizer.sanitize("http://example.com") == "http://example.com")
    }

    @Test func stripsTrailingSentencePunctuation() {
        #expect(URLSanitizer.sanitize("https://example.com).") == "https://example.com")
        #expect(URLSanitizer.sanitize("https://example.com/a,") == "https://example.com/a")
    }

    @Test func rejectsNonHttpSchemes() {
        #expect(URLSanitizer.sanitize("ftp://example.com") == nil)
        #expect(URLSanitizer.sanitize("javascript:alert(1)") == nil)
        #expect(URLSanitizer.sanitize("file:///etc/passwd") == nil)
    }

    @Test func rejectsEmbeddedCredentials() {
        #expect(URLSanitizer.sanitize("https://user:pass@example.com") == nil)
    }

    @Test func rejectsMissingHost() {
        #expect(URLSanitizer.sanitize("https://") == nil)
    }

    @Test func rejectsOversizeURL() {
        let huge = "https://example.com/" + String(repeating: "a", count: 2048)
        #expect(URLSanitizer.sanitize(huge) == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter URLSanitizerTests`
Expected: FAIL — `cannot find 'URLSanitizer' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/URLSanitizer.swift`:
```swift
import Foundation

/// Security-sensitive URL sanitizer for the capture parser (product spec §6.2).
/// Accepts only http/https with a real host, no embedded credentials, under the
/// length cap, with trailing sentence punctuation stripped. Returns nil if unsafe.
public enum URLSanitizer {
    public static let maxLength = 2048
    private static let trailingPunctuation: Set<Character> = [",", ";", ":", ".", "!", "?", ")"]

    public static func sanitize(_ candidate: String) -> String? {
        // Strip trailing sentence punctuation (may be several, e.g. ").").
        var trimmed = candidate
        while let last = trimmed.last, trailingPunctuation.contains(last) {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, trimmed.count < maxLength else { return nil }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }

        // Reject embedded credentials (user:pass@host).
        guard components.user == nil, components.password == nil else { return nil }

        return trimmed
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter URLSanitizerTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/URLSanitizer.swift GSDKit/Tests/GSDModelTests/URLSanitizerTests.swift
git commit -m "feat: add security-sensitive URL sanitizer for capture"
```

### Task A2: CaptureParser

**Files:**
- Create: `GSDKit/Sources/GSDModel/CaptureParser.swift`
- Test: `GSDKit/Tests/GSDModelTests/CaptureParserTests.swift`

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDModelTests/CaptureParserTests.swift`:
```swift
import Testing
@testable import GSDModel

struct CaptureParserTests {
    @Test func doubleExclamationSetsUrgentAndImportant() {
        let r = CaptureParser.parse("Ship the build !!")
        #expect(r.urgent && r.important)
        #expect(r.title == "Ship the build")
    }

    @Test func singleExclamationSetsUrgentOnly() {
        let r = CaptureParser.parse("Call dentist !")
        #expect(r.urgent && !r.important)
        #expect(r.title == "Call dentist")
    }

    @Test func asteriskSetsImportant() {
        let r = CaptureParser.parse("Plan roadmap *")
        #expect(!r.urgent && r.important)
        #expect(r.title == "Plan roadmap")
    }

    @Test func doubleExclamationTakesPrecedenceOverSingle() {
        let r = CaptureParser.parse("Urgent thing !!")
        #expect(r.urgent && r.important)
    }

    @Test func hashTagsLowercasedAndDeduplicated() {
        let r = CaptureParser.parse("Buy milk #Errand #errand #Home")
        #expect(r.tags == ["errand", "home"])
        #expect(r.title == "Buy milk")
    }

    @Test func tagsCappedAt20() {
        let many = (1...25).map { "#t\($0)" }.joined(separator: " ")
        let r = CaptureParser.parse("Task \(many)")
        #expect(r.tags.count == 20)
    }

    @Test func noFlagsLeavesBothFalse() {
        let r = CaptureParser.parse("Just a note")
        #expect(!r.urgent && !r.important)
        #expect(r.title == "Just a note")
    }

    @Test func validURLMovedToDescriptionAdditions() {
        let r = CaptureParser.parse("Read this https://example.com/post later")
        #expect(r.descriptionAdditions == ["https://example.com/post"])
        #expect(r.title == "Read this later")
    }

    @Test func unsafeURLLeftInTitle() {
        let r = CaptureParser.parse("see ftp://example.com now")
        #expect(r.descriptionAdditions.isEmpty)
        #expect(r.title.contains("ftp://example.com"))
    }

    @Test func titleEmptiedByURLBecomesReviewLinkBelow() {
        let r = CaptureParser.parse("https://example.com/x")
        #expect(r.title == "Review link below")
        #expect(r.descriptionAdditions == ["https://example.com/x"])
    }

    @Test func collapsesWhitespaceAfterRemoval() {
        let r = CaptureParser.parse("a   !!   b")
        #expect(r.title == "a b")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd GSDKit && swift test --filter CaptureParserTests`
Expected: FAIL — `cannot find 'CaptureParser' in scope`.

- [ ] **Step 3: Write minimal implementation**

`GSDKit/Sources/GSDModel/CaptureParser.swift`:
```swift
import Foundation

/// Result of parsing a capture string (product spec §6.2). The quadrant is
/// derived from `urgent`/`important` by the caller; a manual override (UI state)
/// can supersede the flags before a Task is built.
public struct ParsedCapture: Equatable, Sendable {
    public var title: String
    public var urgent: Bool
    public var important: Bool
    public var tags: [String]
    public var descriptionAdditions: [String]   // sanitized URLs to append to description
}

/// Parses the capture shorthand: `!!`/`!`/`*` flags, `#tag`s, and http(s) URLs.
/// Tokens are matched on word boundaries; `!!` takes precedence over `!`.
public enum CaptureParser {
    public static func parse(_ input: String) -> ParsedCapture {
        var working = input
        var urgent = false
        var important = false
        var tags: [String] = []
        var urls: [String] = []

        // 1. Extract URL-like words first (before token stripping mangles them).
        var remainingWords: [String] = []
        for word in working.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = String(word)
            if token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://") {
                if let safe = URLSanitizer.sanitize(token) {
                    if !urls.contains(safe) { urls.append(safe) }
                    continue   // drop the URL word from the title
                }
            }
            remainingWords.append(token)
        }
        working = remainingWords.joined(separator: " ")

        // 2. Tags: #tag on word boundaries, lowercased, deduped, capped at 20.
        // NOTE: extended-delimiter regex literals (#/.../#) are REQUIRED — bare
        // /.../ literals hit Swift's operator-ambiguity parse error on `+`/`*`
        // (e.g. /\s+/ fails with "'+/' is not an operator"). Verified by probe.
        let tagMatches = working.matches(of: #/(?:^|\s)#(\w[\w-]*)/#)
        for match in tagMatches {
            let tag = String(match.1).lowercased()
            if !tags.contains(tag) && tags.count < FieldLimits.maxTags {
                tags.append(tag)
            }
        }
        working = working.replacing(#/(?:^|\s)#\w[\w-]*/#, with: "")

        // 3. Flags on word boundaries. `!!` before `!`.
        if working.contains(#/(?:^|\s)!!(?:\s|$)/#) { urgent = true; important = true }
        else if working.contains(#/(?:^|\s)!(?:\s|$)/#) { urgent = true }
        if working.contains(#/(?:^|\s)\*(?:\s|$)/#) { important = true }
        working = working.replacing(#/(?:^|\s)(?:!!|!|\*)(?=\s|$)/#, with: "")

        // 4. Collapse whitespace.
        var title = working.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Empty-title-with-URL fallback.
        if title.isEmpty && !urls.isEmpty {
            title = String(localized: "Review link below")
        }

        return ParsedCapture(title: title, urgent: urgent, important: important,
                             tags: tags, descriptionAdditions: urls)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd GSDKit && swift test --filter CaptureParserTests`
Expected: PASS (11 tests). If a regex edge case fails (word boundaries are subtle), fix the regex — do NOT loosen the test. The authoritative rules are §6.2.

- [ ] **Step 5: Commit**

```bash
git add GSDKit/Sources/GSDModel/CaptureParser.swift GSDKit/Tests/GSDModelTests/CaptureParserTests.swift
git commit -m "feat: add capture shorthand parser"
```

> The parser logic + all 11 cases above were empirically verified against the installed toolchain via a standalone probe before this plan shipped, including the extended-delimiter regex requirement.

---

## Group B — App foundation (store, theme, preferences, wiring)

### Task B1: Quadrant ↔ flags reverse mapping (GSDModel)

**Files:**
- Modify: `GSDKit/Sources/GSDModel/Quadrant.swift`
- Test: `GSDKit/Tests/GSDModelTests/QuadrantTests.swift` (extend existing)

- [ ] **Step 1: Add failing tests** to `QuadrantTests.swift`:
```swift
@Test func reverseMappingExposesFlags() {
    #expect(Quadrant.urgentImportant.isUrgent && Quadrant.urgentImportant.isImportant)
    #expect(Quadrant.notUrgentImportant.isImportant && !Quadrant.notUrgentImportant.isUrgent)
    #expect(Quadrant.urgentNotImportant.isUrgent && !Quadrant.urgentNotImportant.isImportant)
    #expect(!Quadrant.notUrgentNotImportant.isUrgent && !Quadrant.notUrgentNotImportant.isImportant)
}
@Test func reverseMappingRoundTripsWithDerivation() {
    for q in Quadrant.allCases { #expect(Quadrant(urgent: q.isUrgent, important: q.isImportant) == q) }
}
```
- [ ] **Step 2:** `cd GSDKit && swift test --filter QuadrantTests` → FAIL (`isUrgent` not found).
- [ ] **Step 3:** Add to `Quadrant` in `Quadrant.swift`:
```swift
public var isUrgent: Bool { self == .urgentImportant || self == .urgentNotImportant }
public var isImportant: Bool { self == .urgentImportant || self == .notUrgentImportant }
```
- [ ] **Step 4:** `swift test --filter QuadrantTests` → PASS.
- [ ] **Step 5:** Commit: `git commit -am "feat: add Quadrant reverse mapping to flags"`

### Task B2: Theme, quadrant styling, preferences, project polish

**Files:**
- Create: `App/Theme/Theme.swift`, `App/Theme/QuadrantStyle.swift`, `App/Store/AppPreferences.swift`
- Create: `App/Assets.xcassets/` with an empty `AppIcon.appiconset` (clears the Phase-0 missing-icon warning)
- Modify: `project.yml` (fold in Phase-0 deferred polish: project-level `SWIFT_VERSION`, `CODE_SIGN_IDENTITY`), then `xcodegen generate`

This task is build-verified (no unit test — it's styling + config). 

- [ ] **Step 1:** Add a project-level settings block and fix the signing identity in `project.yml` (top level, sibling of `packages:`):
```yaml
settings:
  base:
    SWIFT_VERSION: "6.0"
    CODE_SIGN_IDENTITY: "Apple Development"
```
(Leave the `targets.GSD.settings.base` block as-is; target settings still win.)

- [ ] **Step 2:** Create `App/Theme/Theme.swift`:
```swift
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension Font {
    /// Editorial serif display headings (Apple "New York"). Dynamic Type aware.
    static func serif(_ style: Font.TextStyle) -> Font { .system(style, design: .serif) }
}
```

- [ ] **Step 3:** Create `App/Theme/QuadrantStyle.swift`:
```swift
import SwiftUI
import GSDModel

/// Accent color (light/dark adaptive) + SF Symbol per quadrant.
/// NOTE: verify these meet WCAG AA against card backgrounds in both appearances
/// during the Group D accessibility pass (§12.3) — adjust hex if a pair fails.
enum QuadrantStyle {
    static func accent(_ q: Quadrant) -> Color {
        switch q {
        case .urgentImportant:       Color(light: 0xB23A2E, dark: 0xE0705F) // rust
        case .notUrgentImportant:    Color(light: 0x2C6E8F, dark: 0x5FA8CC) // ocean
        case .urgentNotImportant:    Color(light: 0x8A6D1F, dark: 0xCBB264) // olive/amber
        case .notUrgentNotImportant: Color(light: 0x636363, dark: 0x9B9B9B) // gray
        }
    }
    static func symbol(_ q: Quadrant) -> String {
        switch q {
        case .urgentImportant: "flame.fill"
        case .notUrgentImportant: "calendar"
        case .urgentNotImportant: "person.2.fill"
        case .notUrgentNotImportant: "trash"
        }
    }
}

extension Color {
    /// Light/dark adaptive color from two 0xRRGGBB values.
    init(light: UInt, dark: UInt) {
        self = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
```

- [ ] **Step 4:** Create `App/Store/AppPreferences.swift`:
```swift
import Foundation

enum AppGroup { static let id = "group.dev.vinny.gsd" }

extension UserDefaults {
    /// Shared App-Group defaults; falls back to `.standard` if the group is
    /// unavailable (e.g. a plain simulator run without the entitlement).
    static let shared = UserDefaults(suiteName: AppGroup.id) ?? .standard
}
```

- [ ] **Step 5:** Create `App/Assets.xcassets/Contents.json`:
```json
{ "info" : { "author" : "xcode", "version" : 1 } }
```
and `App/Assets.xcassets/AppIcon.appiconset/Contents.json`:
```json
{ "images" : [ { "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" } ],
  "info" : { "author" : "xcode", "version" : 1 } }
```

- [ ] **Step 6:** Regenerate + build: `xcodegen generate` then
  `xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet` → `** BUILD SUCCEEDED **` (the missing-icon warning should be gone).
- [ ] **Step 7:** Commit: `git add App project.yml GSD.xcodeproj && git commit -m "feat: add theme, quadrant styling, prefs; fold in Phase 0 project polish"`

### Task B3: TaskStore (the observable mutation path)

**Files:**
- Create: `GSDKit/Sources/GSDStore/TaskStore.swift`
- Test: `GSDKit/Tests/GSDStoreTests/TaskStoreTests.swift`

`TaskStore` lives in `GSDStore` (not the app target) so it's testable via `swift test`. It depends only on `GSDModel` + the `TaskRepository` protocol — no SwiftUI (`@Observable` is from the Observation module, not SwiftUI).

- [ ] **Step 1: Write the failing test**

`GSDKit/Tests/GSDStoreTests/TaskStoreTests.swift`:
```swift
import Testing
import Foundation
import GSDModel
@testable import GSDStore

@MainActor
struct TaskStoreTests {
    private let fixed = Date(timeIntervalSince1970: 1000)

    private func makeStoreAndRepo() throws -> (TaskStore, GRDBTaskRepository) {
        let repo = GRDBTaskRepository(try AppDatabase.inMemory(), now: { Date(timeIntervalSince1970: 1000) })
        let store = TaskStore(repository: repo, clock: { Date(timeIntervalSince1970: 1000) }, newID: { "fixed-id" })
        return (store, repo)
    }

    @Test func addBuildsValidatedTaskFromParse() async throws {
        let (store, repo) = try makeStoreAndRepo()
        try await store.add(ParsedCapture(title: "Buy milk", urgent: true, important: true,
                                          tags: ["errand"], descriptionAdditions: ["https://x.com"]))
        let stored = try await repo.fetch(id: "fixed-id")
        #expect(stored?.title == "Buy milk")
        #expect(stored?.quadrant == .urgentImportant)
        #expect(stored?.tags == ["errand"])
        #expect(stored?.description == "https://x.com")
        #expect(stored?.createdAt == fixed && stored?.updatedAt == fixed)
    }

    @Test func addAppliesQuadrantOverride() async throws {
        let (store, repo) = try makeStoreAndRepo()
        try await store.add(ParsedCapture(title: "X", urgent: false, important: false, tags: [], descriptionAdditions: []),
                            override: .urgentImportant)
        #expect(try await repo.fetch(id: "fixed-id")?.quadrant == .urgentImportant)
    }

    @Test func toggleCompleteSetsCompletedAtAndBumpsUpdatedAt() async throws {
        let (store, repo) = try makeStoreAndRepo()
        try await store.add(ParsedCapture(title: "X", urgent: false, important: false, tags: [], descriptionAdditions: []))
        var t = try #require(try await repo.fetch(id: "fixed-id"))
        try await store.toggleComplete(t)
        t = try #require(try await repo.fetch(id: "fixed-id"))
        #expect(t.completed && t.completedAt == fixed)
        try await store.toggleComplete(t)
        #expect(try await repo.fetch(id: "fixed-id")?.completedAt == nil)
    }

    @Test func observationPropagatesToTasks() async throws {
        let (store, _) = try makeStoreAndRepo()
        store.start()
        try await store.add(ParsedCapture(title: "Visible", urgent: false, important: false, tags: [], descriptionAdditions: []))
        // Drain until the snapshot reflects the insert (observation is async).
        var waited = 0
        while store.tasks.isEmpty && waited < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1 }
        #expect(store.tasks.first?.title == "Visible")
    }

    @Test func tasksInQuadrantSortsIncompleteFirst() async throws {
        let (store, repo) = try makeStoreAndRepo()
        let now = Date(timeIntervalSince1970: 1000)
        try await repo.upsert(Task(id: "done", title: "done", urgent: true, important: true,
                                   completed: true, createdAt: now, updatedAt: now))
        try await repo.upsert(Task(id: "open", title: "open", urgent: true, important: true,
                                   createdAt: now, updatedAt: now))
        store.start()
        var waited = 0
        while store.tasks.count < 2 && waited < 100 { try await _Concurrency.Task.sleep(for: .milliseconds(10)); waited += 1 }
        let q1 = store.tasks(in: .urgentImportant, showCompleted: true)
        #expect(q1.map(\.id) == ["open", "done"])
        #expect(store.tasks(in: .urgentImportant, showCompleted: false).map(\.id) == ["open"])
    }
}
```

- [ ] **Step 2:** `cd GSDKit && swift test --filter TaskStoreTests` → FAIL (`TaskStore` not found).

- [ ] **Step 3: Write the implementation**

`GSDKit/Sources/GSDStore/TaskStore.swift`:
```swift
import Foundation
import GSDModel

/// The single mutation path and observable task snapshot for the UI. Bridges
/// `TaskRepository.observeAll()` into `tasks`, and stamps `updatedAt` (via an
/// injected clock) on every PRIMARY mutation — satisfying the §3.3 invariant at
/// the use-case layer (the repository only stamps its own cascade side-effects).
@MainActor
@Observable
public final class TaskStore {
    public private(set) var tasks: [Task] = []

    private let repository: any TaskRepository
    private let clock: @Sendable () -> Date
    private let newID: @Sendable () -> String
    private var observerTask: _Concurrency.Task<Void, Never>?

    public init(
        repository: any TaskRepository,
        clock: @escaping @Sendable () -> Date = { Date() },
        newID: @escaping @Sendable () -> String = { IDGenerator.generate(size: IDGenerator.Size.task) }
    ) {
        self.repository = repository
        self.clock = clock
        self.newID = newID
    }

    /// Begin observing the repository. Idempotent; call once from the app root.
    public func start() {
        guard observerTask == nil else { return }
        let stream = repository.observeAll()
        observerTask = _Concurrency.Task { [weak self] in
            do {
                for try await snapshot in stream { self?.tasks = snapshot }
            } catch {
                // Observation ended with an error; keep the last snapshot.
            }
        }
    }

    deinit { observerTask?.cancel() }

    // MARK: Mutations (all stamp updatedAt via the injected clock)

    public func add(_ parsed: ParsedCapture, override: Quadrant? = nil) async throws {
        let now = clock()
        let task = Task(
            id: newID(), title: parsed.title,
            description: parsed.descriptionAdditions.joined(separator: "\n"),
            urgent: override?.isUrgent ?? parsed.urgent,
            important: override?.isImportant ?? parsed.important,
            createdAt: now, updatedAt: now, tags: parsed.tags
        )
        try TaskValidator.validate(task)
        try await repository.upsert(task)
    }

    public func save(_ task: Task) async throws {
        var t = task; t.updatedAt = clock()
        try TaskValidator.validate(t)
        try await repository.upsert(t)
    }

    public func toggleComplete(_ task: Task) async throws {
        var t = task; let now = clock()
        t.completed.toggle()
        t.completedAt = t.completed ? now : nil
        t.updatedAt = now
        try await repository.upsert(t)   // recurrence spawning on completion is Phase 2
    }

    public func move(_ task: Task, to quadrant: Quadrant) async throws {
        var t = task
        t.urgent = quadrant.isUrgent; t.important = quadrant.isImportant
        t.updatedAt = clock()
        try await repository.upsert(t)
    }

    public func delete(_ task: Task) async throws { try await repository.delete(id: task.id) }

    // MARK: Reads

    public func tasks(in quadrant: Quadrant, showCompleted: Bool) -> [Task] {
        tasks
            .filter { $0.quadrant == quadrant && (showCompleted || !$0.completed) }
            .sorted { a, b in a.completed == b.completed ? a.updatedAt > b.updatedAt : !a.completed }
    }
}
```

- [ ] **Step 4:** `cd GSDKit && swift test --filter TaskStoreTests` → PASS (5 tests). If `observationPropagatesToTasks` is flaky, raise the wait bound; do not delete the assertion.
- [ ] **Step 5:** Commit: `git add GSDKit/Sources/GSDStore/TaskStore.swift GSDKit/Tests/GSDStoreTests/TaskStoreTests.swift && git commit -m "feat: add observable TaskStore mutation path"`

### Task B4: App wiring + temporary adaptive shell

**Files:**
- Modify: `App/GSDApp.swift`, `App/ContentView.swift`

This wires the live store into the app and proves end-to-end capture→persist→observe works. The temporary list/field UI here is REPLACED by the real matrix in Group D — it exists so Group B is independently runnable.

- [ ] **Step 1:** Replace `App/GSDApp.swift`:
```swift
import SwiftUI
import GSDStore

@main
struct GSDApp: App {
    @State private var store: TaskStore
    @AppStorage("appTheme", store: .shared) private var themeRaw = AppTheme.system.rawValue

    init() {
        // The local store is the app's source of truth; failure to open it is unrecoverable.
        let database = try! AppDatabase.live()
        _store = State(initialValue: TaskStore(repository: GRDBTaskRepository(database)))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .preferredColorScheme(AppTheme(rawValue: themeRaw)?.colorScheme ?? nil)
                .task { store.start() }
        }
    }
}
```

- [ ] **Step 2:** Replace `App/ContentView.swift` with a temporary store smoke-screen:
```swift
import SwiftUI
import GSDModel
import GSDStore

struct ContentView: View {
    @Environment(TaskStore.self) private var store
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            VStack {
                TextField("Capture a task… (try !! and #tag)", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                    .padding()
                List(store.tasks) { task in
                    Text(task.title).strikethrough(task.completed)
                }
            }
            .navigationTitle("GSD")
        }
    }

    private func add() {
        let parsed = CaptureParser.parse(draft)
        guard !parsed.title.isEmpty else { return }
        draft = ""
        _Concurrency.Task { try? await store.add(parsed) }
    }
}
```

- [ ] **Step 3:** Regenerate (new files under App/) + build + launch:
```
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build-app build -quiet
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl install booted ".build-app/Build/Products/Debug-iphonesimulator/GSD.app"
xcrun simctl launch booted dev.vinny.gsd
```
Expected: app launches; typing `Buy milk !! #errand` and submitting shows "Buy milk" in the list (persisted via GRDB, surfaced via observation). Capture a screenshot for confirmation.
- [ ] **Step 4:** Commit: `git add App GSD.xcodeproj && git commit -m "feat: wire live TaskStore into app with temporary capture shell"`

> **Milestone after Group B:** a runnable app where capture (with full parser) → GRDB persistence → observation → UI round-trips. The temporary list UI is replaced by the real matrix in Group D.

---

## Group C — Task card, capture bar, presentation model

> SwiftUI presentation; build-verified via `xcodebuild`. Flag these APIs at build time if they don't compile as written: `@Environment(TaskStore.self)`, `.accessibilityActions`, `Text(markdown:)` link rendering.

### Task C1: EditorRequest (shared presentation model)

**Files:** Create `App/Editor/EditorRequest.swift`

- [ ] **Step 1: Write it** (no test — a trivial enum; build-verified):
```swift
import GSDModel

/// What the editor sheet was opened to do. `Identifiable` so it drives `.sheet(item:)`.
enum EditorRequest: Identifiable {
    case new(Quadrant, prefill: ParsedCapture?)
    case edit(Task)

    var id: String {
        switch self {
        case .new(let q, _): "new-\(q.rawValue)"
        case .edit(let t): t.id
        }
    }
}
```
- [ ] **Step 2: Commit** `git add App/Editor/EditorRequest.swift && git commit -m "feat: add EditorRequest presentation model"`

### Task C2: TaskCardView

**Files:** Create `App/Matrix/TaskCardView.swift`

A pure view of a Phase-1 `Task` (no store dependency — swipe/menu/a11y actions are attached by the section in Group E).

- [ ] **Step 1: Write it:**
```swift
import SwiftUI
import GSDModel

/// One task row. Phase-1 fields only (subtask progress, dependency badges, due
/// date, timer, snooze arrive in Phase 2). Hosts its own VoiceOver label;
/// custom actions are attached by the enclosing section.
struct TaskCardView: View {
    let task: Task

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(QuadrantStyle.accent(task.quadrant))
                .frame(width: 4)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(task.title)
                    .font(.headline)
                    .strikethrough(task.completed)
                    .foregroundStyle(task.completed ? .secondary : .primary)

                if !task.description.isEmpty {
                    Text(task.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !task.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(task.tags, id: \.self) { tag in
                            Text("#\(tag)")
                                .font(.caption2)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(QuadrantStyle.accent(task.quadrant).opacity(0.15), in: Capsule())
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                .imageScale(.large)
                .foregroundStyle(task.completed ? QuadrantStyle.accent(task.quadrant) : .secondary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 44)                 // ≥44pt hit target (§12.3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let state = task.completed ? String(localized: "completed") : String(localized: "active")
        return "\(task.title), \(task.quadrant.title), \(state)"
    }
}
```
- [ ] **Step 2: Build** `xcodegen generate && xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet` → SUCCEEDED.
- [ ] **Step 3: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add TaskCardView"`

### Task C3: CaptureBar

**Files:** Create `App/Matrix/CaptureBar.swift`

- [ ] **Step 1: Write it:**
```swift
import SwiftUI
import GSDModel
import GSDStore

/// Capture field with a live parse preview and a cycling quadrant override.
struct CaptureBar: View {
    @Environment(TaskStore.self) private var store
    @State private var draft = ""
    @State private var override: Quadrant?
    @FocusState private var focused: Bool
    /// Opens the full editor pre-filled from the current parse.
    var onDetails: (ParsedCapture, Quadrant?) -> Void

    private var parsed: ParsedCapture { CaptureParser.parse(draft) }
    private var previewQuadrant: Quadrant {
        override ?? Quadrant(urgent: parsed.urgent, important: parsed.important)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField(String(localized: "Capture a task…  (try !!  *  #tag)"), text: $draft)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(submit)
                Button(action: cycleOverride) {
                    Label(previewQuadrant.title, systemImage: QuadrantStyle.symbol(previewQuadrant))
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(QuadrantStyle.accent(previewQuadrant))
                }
                .buttonStyle(.bordered)
                .accessibilityHint(String(localized: "Cycles the target quadrant"))
            }
            if !draft.isEmpty {
                HStack(spacing: 6) {
                    ForEach(parsed.tags, id: \.self) { tag in
                        Text("#\(tag)").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    Button(String(localized: "Details")) { onDetails(parsed, override) }
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }

    private func submit() {
        let p = CaptureParser.parse(draft)
        guard !p.title.isEmpty else { return }
        let ov = override
        draft = ""; override = nil; focused = true
        _Concurrency.Task { try? await store.add(p, override: ov) }
    }

    private func cycleOverride() {
        let order: [Quadrant?] = [nil, .urgentImportant, .notUrgentImportant,
                                  .urgentNotImportant, .notUrgentNotImportant]
        let i = order.firstIndex(of: override) ?? 0
        override = order[(i + 1) % order.count]
    }
}
```
- [ ] **Step 2: Build** (same command) → SUCCEEDED.
- [ ] **Step 3: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add capture bar with live parse preview"`

## Group D — Task editor

> Built before the matrix (Group E) so the matrix can present it. Build-verified.

### Task D1: TaskEditorView

**Files:** Create `App/Editor/TaskEditorView.swift`

Phase-1 fields only: title, description, quadrant, tags. **Crucially, editing an existing task starts from that task** so Phase-2 fields (subtasks, dependencies, due date, etc.) are preserved on save, not wiped.

- [ ] **Step 1: Write it:**
```swift
import SwiftUI
import GSDModel
import GSDStore

struct TaskEditorView: View {
    @Environment(TaskStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var description: String
    @State private var quadrant: Quadrant
    @State private var tags: [String]
    @State private var tagDraft = ""
    /// The task being edited (nil = creating a new one). Saving an edit mutates
    /// THIS value so non-edited (Phase-2) fields survive.
    private let original: Task?

    init(request: EditorRequest) {
        switch request {
        case .new(let q, let prefill):
            _title = State(initialValue: prefill?.title ?? "")
            _description = State(initialValue: prefill?.descriptionAdditions.joined(separator: "\n") ?? "")
            _quadrant = State(initialValue: prefill.map { Quadrant(urgent: $0.urgent, important: $0.important) } ?? q)
            _tags = State(initialValue: prefill?.tags ?? [])
            original = nil
        case .edit(let t):
            _title = State(initialValue: t.title)
            _description = State(initialValue: t.description)
            _quadrant = State(initialValue: t.quadrant)
            _tags = State(initialValue: t.tags)
            original = t
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section { TextField(String(localized: "Title"), text: $title) }
                Section(String(localized: "Quadrant")) { quadrantPicker }
                Section(String(localized: "Tags")) { tagField }
                Section(String(localized: "Notes")) {
                    TextField(String(localized: "Description"), text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle(original == nil ? String(localized: "New Task") : String(localized: "Edit Task"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save"), action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var quadrantPicker: some View {
        LazyVGrid(columns: [GridItem(), GridItem()], spacing: 8) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button { quadrant = q } label: {
                    VStack(spacing: 4) {
                        Image(systemName: QuadrantStyle.symbol(q))
                        Text(q.title).font(.caption)
                    }
                    .frame(maxWidth: .infinity).padding(8)
                    .background(quadrant == q ? QuadrantStyle.accent(q).opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8)
                        .stroke(QuadrantStyle.accent(q), lineWidth: quadrant == q ? 2 : 0.5))
                }
                .tint(QuadrantStyle.accent(q))
                .accessibilityAddTraits(quadrant == q ? .isSelected : [])
            }
        }
    }

    private var tagField: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !tags.isEmpty {
                HStack {
                    ForEach(tags, id: \.self) { tag in
                        Button { tags.removeAll { $0 == tag } } label: { Text("#\(tag)  ✕").font(.caption2) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            TextField(String(localized: "Add tag"), text: $tagDraft)
                .onSubmit(addTag)
                .onChange(of: tagDraft) { _, new in if new.hasSuffix(",") { addTag() } }
        }
    }

    private func addTag() {
        let t = tagDraft.trimmingCharacters(in: CharacterSet(charactersIn: " ,#")).lowercased()
        tagDraft = ""
        guard !t.isEmpty, !tags.contains(t), tags.count < FieldLimits.maxTags else { return }
        tags.append(t)
    }

    private func save() {
        var task: Task
        if let original {
            task = original
            task.title = title.trimmingCharacters(in: .whitespaces)
            task.description = description
            task.urgent = quadrant.isUrgent
            task.important = quadrant.isImportant
            task.tags = tags
        } else {
            let now = Date.now
            task = Task(id: IDGenerator.generate(size: IDGenerator.Size.task),
                        title: title.trimmingCharacters(in: .whitespaces),
                        description: description,
                        urgent: quadrant.isUrgent, important: quadrant.isImportant,
                        createdAt: now, updatedAt: now, tags: tags)
        }
        _Concurrency.Task { try? await store.save(task); dismiss() }
    }
}
```
- [ ] **Step 2: Build** → SUCCEEDED.
- [ ] **Step 3: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add Phase 1 task editor"`

## Group E — Matrix surfaces + completion

> The phase's visible payoff. Build-verified; the genuinely uncertain APIs to confirm at build: `TimelineView(.animation(paused:))`, `Canvas` per-particle opacity, `.draggable`/`.dropDestination`, `.safeAreaInset`. iPad reclassify uses drag-and-drop (swipe actions need a `List`, so the iPad grid uses context menu + drag instead).

### Task E1: ConfettiView

**Files:** Create `App/Effects/ConfettiView.swift`

- [ ] **Step 1: Write it:**
```swift
import SwiftUI

/// A one-shot confetti burst, fired by incrementing `trigger`. Honors Reduce
/// Motion (§6.4/§12.3): no particles emitted when it's on. Particle counts are a
/// feel reference, freely tunable.
struct ConfettiView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Int

    @State private var particles: [Particle] = []
    @State private var startDate: Date?

    private static let duration: TimeInterval = 1.6

    var body: some View {
        TimelineView(.animation(paused: startDate == nil)) { timeline in
            Canvas { context, size in
                guard let start = startDate else { return }
                let t = timeline.date.timeIntervalSince(start)
                if t > Self.duration { return }
                for p in particles {
                    let pos = p.position(at: t, in: size)
                    var ctx = context
                    ctx.opacity = max(0, 1 - t / Self.duration)
                    ctx.fill(Path(ellipseIn: CGRect(x: pos.x, y: pos.y, width: p.size, height: p.size)),
                             with: .color(p.color))
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in fire() }
    }

    private func fire() {
        guard !reduceMotion else { return }
        particles = (0..<160).map { _ in Particle.random() }
        startDate = .now
    }

    struct Particle {
        var origin: CGPoint          // normalized 0...1
        var velocity: CGVector
        var color: Color
        var size: CGFloat
        func position(at t: TimeInterval, in size: CGSize) -> CGPoint {
            let gravity = 700.0
            return CGPoint(x: origin.x * size.width + velocity.dx * t,
                           y: origin.y * size.height + velocity.dy * t + 0.5 * gravity * t * t)
        }
        static func random() -> Particle {
            let colors: [Color] = [.red, .orange, .yellow, .green, .blue, .purple, .pink]
            let angle = Double.random(in: 0..<2 * .pi)
            let speed = Double.random(in: 150...460)
            return Particle(origin: CGPoint(x: Double.random(in: 0.3...0.7), y: 0.45),
                            velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed - 220),
                            color: colors.randomElement()!, size: .random(in: 5...10))
        }
    }
}
```
- [ ] **Step 2: Build** → SUCCEEDED. (Visual + Reduce-Motion behavior is verified in E5.)
- [ ] **Step 3: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add reduce-motion-aware confetti"`

### Task E2: TaskActions + QuadrantSection (iPhone List section)

**Files:** Create `App/Matrix/TaskActions.swift`, `App/Matrix/QuadrantSection.swift`

- [ ] **Step 1: Write `App/Matrix/TaskActions.swift`** (shared mutation handlers + haptic):
```swift
import SwiftUI
import GSDModel
import GSDStore

/// Bundles the row mutation handlers so the iPhone section and iPad cell share them.
@MainActor
struct TaskActions {
    let store: TaskStore
    let onCompleted: () -> Void   // fire confetti when a task becomes complete

    func toggle(_ t: Task) {
        let willComplete = !t.completed
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        _Concurrency.Task { try? await store.toggleComplete(t); if willComplete { onCompleted() } }
    }
    func delete(_ t: Task) { _Concurrency.Task { try? await store.delete(t) } }
    func move(_ t: Task, to q: Quadrant) { _Concurrency.Task { try? await store.move(t, to: q) } }
}
```

- [ ] **Step 2: Write `App/Matrix/QuadrantSection.swift`:**
```swift
import SwiftUI
import GSDModel
import GSDStore

/// One quadrant as a `List` `Section` (iPhone) — enables native swipe actions.
struct QuadrantSection: View {
    @Environment(TaskStore.self) private var store
    let quadrant: Quadrant
    let showCompleted: Bool
    let actions: TaskActions
    var onEdit: (Task) -> Void
    var onAdd: () -> Void

    private var items: [Task] { store.tasks(in: quadrant, showCompleted: showCompleted) }
    private var activeCount: Int { store.tasks(in: quadrant, showCompleted: false).count }

    var body: some View {
        Section {
            if items.isEmpty {
                Button(action: onAdd) {
                    Label(String(localized: "Add to \(quadrant.title)"), systemImage: "plus.circle")
                }
                .foregroundStyle(.secondary)
            } else {
                ForEach(items) { task in
                    TaskCardView(task: task)
                        .onTapGesture { onEdit(task) }
                        .swipeActions(edge: .leading) {
                            Button { actions.toggle(task) } label: {
                                Label(task.completed ? "Uncomplete" : "Complete",
                                      systemImage: task.completed ? "arrow.uturn.left" : "checkmark")
                            }
                            .tint(QuadrantStyle.accent(quadrant))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { actions.delete(task) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .contextMenu { rowMenu(task) }
                        .accessibilityActions {
                            Button(task.completed ? "Uncomplete" : "Complete") { actions.toggle(task) }
                            Button("Edit") { onEdit(task) }
                            Button("Delete") { actions.delete(task) }
                        }
                }
            }
        } header: {
            HStack {
                Label(quadrant.title, systemImage: QuadrantStyle.symbol(quadrant))
                    .font(.serif(.headline))
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Spacer()
                Text("\(activeCount)")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityLabel(String(localized: "\(activeCount) active"))
            }
        }
    }

    @ViewBuilder private func rowMenu(_ task: Task) -> some View {
        Button { onEdit(task) } label: { Label("Edit", systemImage: "pencil") }
        Button { actions.toggle(task) } label: {
            Label(task.completed ? "Uncomplete" : "Complete", systemImage: "checkmark")
        }
        Menu(String(localized: "Move to")) {
            ForEach(Quadrant.allCases, id: \.self) { q in
                Button(q.title) { actions.move(task, to: q) }
            }
        }
        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
    }
}
```
- [ ] **Step 3: Build** → SUCCEEDED.
- [ ] **Step 4: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add task actions and iPhone quadrant section"`

---

### Task E3: QuadrantCell (iPad grid cell with drag-and-drop)

**Files:** Create `App/Matrix/QuadrantCell.swift`

A self-contained boxed quadrant for the iPad 2×2 grid (no `List`, so no swipe — uses context menu + tap + drag-and-drop instead).

- [ ] **Step 1: Write it:**
```swift
import SwiftUI
import GSDModel
import GSDStore

struct QuadrantCell: View {
    @Environment(TaskStore.self) private var store
    let quadrant: Quadrant
    let showCompleted: Bool
    let actions: TaskActions
    var onEdit: (Task) -> Void
    var onAdd: () -> Void

    @State private var isTargeted = false
    private var items: [Task] { store.tasks(in: quadrant, showCompleted: showCompleted) }
    private var activeCount: Int { store.tasks(in: quadrant, showCompleted: false).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(quadrant.title, systemImage: QuadrantStyle.symbol(quadrant))
                    .font(.serif(.headline))
                    .foregroundStyle(QuadrantStyle.accent(quadrant))
                Spacer()
                Text("\(activeCount)").font(.caption).foregroundStyle(.secondary)
            }
            if items.isEmpty {
                Button(action: onAdd) {
                    Label(String(localized: "Add to \(quadrant.title)"), systemImage: "plus.circle")
                }
                .foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(items) { task in
                TaskCardView(task: task)
                    .onTapGesture { onEdit(task) }
                    .draggable(task.id)
                    .contextMenu {
                        Button { onEdit(task) } label: { Label("Edit", systemImage: "pencil") }
                        Button { actions.toggle(task) } label: {
                            Label(task.completed ? "Uncomplete" : "Complete", systemImage: "checkmark")
                        }
                        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: "trash") }
                    }
                    .accessibilityActions {
                        Button(task.completed ? "Uncomplete" : "Complete") { actions.toggle(task) }
                        Button("Edit") { onEdit(task) }
                        Button("Delete") { actions.delete(task) }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(QuadrantStyle.accent(quadrant).opacity(isTargeted ? 0.12 : 0.04),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(QuadrantStyle.accent(quadrant).opacity(0.3)))
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let task = store.tasks.first(where: { $0.id == id }) else { return false }
            actions.move(task, to: quadrant)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}
```
- [ ] **Step 2: Build** → SUCCEEDED.
- [ ] **Step 3: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add iPad quadrant cell with drag-and-drop"`

### Task E4: MatrixView (iPhone) + MatrixGridView (iPad)

**Files:** Create `App/Matrix/MatrixView.swift`, `App/Matrix/MatrixGridView.swift`

- [ ] **Step 1: Write `App/Matrix/MatrixView.swift`:**
```swift
import SwiftUI
import GSDModel
import GSDStore

/// iPhone: capture bar + a List of stacked quadrant sections (Q1→Q4).
struct MatrixView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0

    var body: some View {
        ZStack {
            NavigationStack {
                List {
                    ForEach(Quadrant.allCases, id: \.self) { q in
                        QuadrantSection(
                            quadrant: q, showCompleted: showCompleted,
                            actions: TaskActions(store: store) { confettiTrigger += 1 },
                            onEdit: { editor = .edit($0) },
                            onAdd: { editor = .new(q, prefill: nil) }
                        )
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("Matrix")
                .toolbar { showCompletedToggle($showCompleted) }
                .safeAreaInset(edge: .top) {
                    CaptureBar { parsed, ov in
                        editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
                    }
                }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .sheet(item: $editor) { TaskEditorView(request: $0) }
    }
}

@ToolbarContentBuilder
func showCompletedToggle(_ binding: Binding<Bool>) -> some ToolbarContent {
    ToolbarItem(placement: .topBarTrailing) {
        Toggle(isOn: binding) { Label("Show Completed", systemImage: "checkmark.circle") }
            .toggleStyle(.button)
    }
}
```

- [ ] **Step 2: Write `App/Matrix/MatrixGridView.swift`:**
```swift
import SwiftUI
import GSDModel
import GSDStore

/// iPad: capture bar + a true 2×2 grid (Q1 TL → Q4 BR).
struct MatrixGridView: View {
    @Environment(TaskStore.self) private var store
    @AppStorage("showCompleted", store: .shared) private var showCompleted = false
    @State private var editor: EditorRequest?
    @State private var confettiTrigger = 0

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ZStack {
            NavigationStack {
                VStack(spacing: 0) {
                    CaptureBar { parsed, ov in
                        editor = .new(ov ?? Quadrant(urgent: parsed.urgent, important: parsed.important), prefill: parsed)
                    }
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(Quadrant.allCases, id: \.self) { q in
                                QuadrantCell(
                                    quadrant: q, showCompleted: showCompleted,
                                    actions: TaskActions(store: store) { confettiTrigger += 1 },
                                    onEdit: { editor = .edit($0) },
                                    onAdd: { editor = .new(q, prefill: nil) }
                                )
                            }
                        }
                        .padding(12)
                    }
                }
                .navigationTitle("Matrix")
                .toolbar { showCompletedToggle($showCompleted) }
            }
            ConfettiView(trigger: confettiTrigger)
        }
        .sheet(item: $editor) { TaskEditorView(request: $0) }
    }
}
```
- [ ] **Step 3: Build** → SUCCEEDED.
- [ ] **Step 4: Commit** `git add App GSD.xcodeproj && git commit -m "feat: add iPhone stacked and iPad 2x2 matrix views"`

### Task E5: Wire the adaptive root + verify

**Files:** Modify `App/ContentView.swift`

- [ ] **Step 1: Replace `App/ContentView.swift`** (drops the temporary shell):
```swift
import SwiftUI

/// Adaptive root: stacked matrix on compact width (iPhone), 2×2 grid on regular (iPad).
struct ContentView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .compact {
            MatrixView()
        } else {
            MatrixGridView()
        }
    }
}
```
- [ ] **Step 2: Build, launch, and verify on BOTH idioms:**
```
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build-app build -quiet
xcrun simctl boot "iPhone 17" 2>/dev/null || true
xcrun simctl install booted ".build-app/Build/Products/Debug-iphonesimulator/GSD.app"
xcrun simctl launch booted dev.vinny.gsd
xcrun simctl io booted screenshot /tmp/phase1-iphone.png
```
Repeat the build/install/launch/screenshot for an iPad simulator (e.g. `-destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'`; list available with `xcrun simctl list devices available | grep iPad`).
Expected: capture `Plan the offsite ! #work`, see it land in **Delegate (Q3)**; swipe-complete on iPhone shows confetti; drag a card between cells on iPad reclassifies it; toggling Show Completed reveals/hides the completed card.

- [ ] **Step 3: Accessibility pass** (manual, §12.3): run with Dynamic Type at the largest accessibility size (Settings or `-AppleTextDirection`/Accessibility Inspector) — confirm no clipped text and the matrix reflows. Run a VoiceOver pass on the matrix + editor — confirm each card reads "title, quadrant, state" and exposes Complete/Edit/Delete custom actions. Toggle Reduce Motion and confirm completion fires NO confetti. Record any blocking issues as fixes before closing the phase.

- [ ] **Step 4: Commit** `git add App GSD.xcodeproj && git commit -m "feat: wire adaptive matrix root; remove temporary shell"`

---

## Phase 1 — Definition of Done

- [ ] `swift test` green for all GSDModel + GSDStore additions (parser, sanitizer, Quadrant reverse map, TaskStore).
- [ ] Capture with the full shorthand (`!`/`!!`/`*`/`#tag`/URL) creates correctly-classified tasks (spec **A4/A5**).
- [ ] Matrix renders 4 quadrants with live counts and respects show-completed; iPhone stacked / iPad 2×2 (**A6**).
- [ ] Completing a task sets `completedAt`, fires a success haptic + confetti, suppressed under Reduce Motion (**A7**).
- [ ] iPad drag-and-drop moves a card between quadrants and updates the flags (**A8**).
- [ ] Editor validates limits and disables Save on empty title (**A13**, Phase-1 subset of fields).
- [ ] Dynamic Type (max) + VoiceOver pass on matrix + editor with no blocking issues (**A15**).
- [ ] One commit per task; app builds + launches on iPhone and iPad simulators.
