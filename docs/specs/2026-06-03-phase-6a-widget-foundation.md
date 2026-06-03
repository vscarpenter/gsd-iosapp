# Phase 6a — Native Foundation + Today's Focus Widget

**Status:** SPEC — awaiting user review (brainstorming gate)
**Date:** 2026-06-03
**Branch:** `phase-6a-widget-foundation`
**Depends on:** Phases 0–5 complete (GSDModel/GSDStore/GSDSync, App Group, sync engine)

---

## 1. Goal

Ship the first native-surface slice: a **Today's Focus home-screen widget** backed by a
precomputed App-Group snapshot, plus the reusable foundation (a GRDB-free shared module, the
snapshot refresh pathway, and `gsd://` deep-linking) that later 6x slices build on.

One sentence: *the app writes a lightweight snapshot whenever its task set changes; a GRDB-free
widget reads it and renders the urgent+important tasks, and tapping the widget opens the app.*

## 2. Scope

**In:**
- New GRDB-free shared module `GSDSnapshot` (app↔widget contract).
- `WidgetSnapshot` data + `WidgetSnapshotStore` (atomic App-Group JSON) + `WidgetSnapshotBuilder`.
- `WidgetSnapshotRefresher` in the app, driven by a new `TaskStore.onTasksChanged` callback.
- A `GSDWidgets` app-extension target with the Today's Focus widget (`systemSmall` + `systemMedium`).
- `gsd://` URL scheme + `.onOpenURL` routing; `gsd://focus` → Matrix.
- Move the App-Group ID constant into GSDModel.

**Out (deferred to later slices):**
- Per-task deep-links (`gsd://task/<id>`) and task-detail navigation plumbing.
- Other widget families/types (Lock Screen accessory, Quadrant Overview, Upcoming Deadlines).
- App Intents / Siri / Spotlight (6c). Share Extension (6d). Keychain access group.
- Background-task-driven snapshot writes while the app is suspended (the widget's own timeline
  plus next-foreground refresh cover this; see §9).

## 3. Architecture

### 3.1 Module / target graph

```
GSDModel  (no deps)                ← owns Task, FilterCriteria, TaskFilter, BuiltInSmartViews, AppGroup.id
   ↑            ↑
GSDStore     GSDSnapshot  (NEW, → GSDModel only, NO GRDB)
(GRDB)          ↑     ↑
   ↑            |     |
   |         GSDWidgets (NEW app-extension, → GSDModel + GSDSnapshot, NO GRDB)
   |            |
  GSD app  →  GSDModel + GSDStore + GSDSync + GSDSnapshot, embeds GSDWidgets
```

The widget extension never links GRDB. Only the app (which already has GRDB via `TaskStore`)
writes the snapshot; the widget only reads it.

### 3.2 Data flow

```
TaskStore.observeAll() emits  →  self.tasks = snapshot  →  onTasksChanged?()   [GSDStore]
        (local edit / remote SSE / pull / BGTask sync all flow through here)
                                          │
                                          ▼
WidgetSnapshotRefresher (debounce ~1s)  →  WidgetSnapshotBuilder.todaysFocus(...)   [App]
                                          →  WidgetSnapshotStore.write(...)  (atomic)
                                          →  WidgetCenter.shared.reloadAllTimelines()
                                          │
                                          ▼  (App-Group container file)
TodaysFocusProvider.getTimeline  →  WidgetSnapshotStore.read()  →  one entry, .never   [GSDWidgets]
                                          │
                                          ▼
TodaysFocusView renders rows; widgetURL = gsd://focus
                                          │  (tap)
                                          ▼
GSDApp.onOpenURL  →  DeepLinkParser.route(from:)  →  navigate(to: .matrix)   [App]
```

## 4. Components

### 4.1 GSDModel — `AppGroup.id` (moved constant)

`GSDKit/Sources/GSDModel/AppGroup.swift`:

```swift
public enum AppGroup {
    public static let id = "group.dev.vinny.gsd"
}
```

`StoreLocation.appGroupID` is changed to reference `AppGroup.id` (keeps one source of truth;
GSDStore already depends on GSDModel). GSDSnapshot uses `AppGroup.id` directly.

### 4.2 GSDSnapshot — the shared contract

`GSDKit/Sources/GSDSnapshot/WidgetSnapshot.swift`:

```swift
import Foundation

public struct WidgetSnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var tasks: [WidgetTask]   // already limited
    public var totalCount: Int       // total matching today-focus (for "+N more")
    public init(generatedAt: Date, tasks: [WidgetTask], totalCount: Int) {
        self.generatedAt = generatedAt; self.tasks = tasks; self.totalCount = totalCount
    }
    public static let empty = WidgetSnapshot(generatedAt: .distantPast, tasks: [], totalCount: 0)
}

public struct WidgetTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var dueDate: Date?
    public init(id: String, title: String, dueDate: Date?) {
        self.id = id; self.title = title; self.dueDate = dueDate
    }
}
```

`GSDKit/Sources/GSDSnapshot/WidgetSnapshotBuilder.swift`:

```swift
import Foundation
import GSDModel

public enum WidgetSnapshotBuilder {
    public static let todaysFocusViewID = "today-focus"

    /// Pure projection of the app's task set onto the Today's Focus widget snapshot.
    /// Reuses the SAME criteria + filter the in-app smart view uses, so the widget can never drift.
    public static func todaysFocus(
        from tasks: [Task], now: Date, calendar: Calendar = .current, limit: Int = 8
    ) -> WidgetSnapshot {
        let criteria = BuiltInSmartViews.all
            .first { $0.id == todaysFocusViewID }!.criteria
        let matched = TaskFilter.apply(criteria, to: tasks, now: now, calendar: calendar)
        let rows = matched.prefix(limit).map {
            WidgetTask(id: $0.id, title: $0.title, dueDate: $0.dueDate)
        }
        return WidgetSnapshot(generatedAt: now, tasks: Array(rows), totalCount: matched.count)
    }
}
```

`GSDKit/Sources/GSDSnapshot/WidgetSnapshotStore.swift`:

```swift
import Foundation
import GSDModel

public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-today-focus.json"
    private let containerURL: URL?

    /// Production: resolves the App-Group container (GRDB-free; pure Foundation).
    public init(appGroupID: String = AppGroup.id, fileManager: FileManager = .default) {
        self.containerURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }
    /// Test seam: inject a temp directory.
    public init(containerURL: URL?) { self.containerURL = containerURL }

    private var fileURL: URL? { containerURL?.appendingPathComponent(Self.fileName) }

    public func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = fileURL else { throw WidgetSnapshotError.noContainer }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)   // write-temp-then-rename: widget never sees a partial file
    }

    /// Returns nil on missing/unreadable/corrupt — first launch and decode failures degrade to empty.
    public func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

public enum WidgetSnapshotError: Error { case noContainer }
```

`GSDKit/Sources/GSDSnapshot/DeepLink.swift`:

```swift
import Foundation

public enum DeepLinkRoute: Equatable, Sendable {
    case focus
    public var url: URL { URL(string: "gsd://focus")! }
}

public enum DeepLinkParser {
    /// Maps a `gsd://` URL to an app route. Returns nil for anything we don't own —
    /// crucially `gsd://oauth-callback` (ASWebAuthenticationSession's callback) so a stray
    /// delivery to .onOpenURL is ignored idempotently.
    public static func route(from url: URL) -> DeepLinkRoute? {
        guard url.scheme == "gsd" else { return nil }
        switch url.host {
        case "focus": return .focus
        default:      return nil   // includes "oauth-callback"
        }
    }
}
```

### 4.3 GSDStore — `TaskStore.onTasksChanged`

`GSDKit/Sources/GSDStore/TaskStore.swift`:
- Add next to `onMutation` (line 47):
  ```swift
  /// Fired after every observed task-set change (local + remote + background sync), with the new
  /// value already committed to `tasks`. Drives the widget snapshot (6a). Not observed.
  @ObservationIgnored public var onTasksChanged: (() -> Void)?
  ```
- In `startTaskObserver` (line 87), fire it after the assignment:
  ```swift
  do { for try await snapshot in stream { self?.tasks = snapshot; self?.onTasksChanged?() } } catch {}
  ```

### 4.4 App — `WidgetSnapshotRefresher`

`App/Widgets/WidgetSnapshotRefresher.swift` (@MainActor): holds the `TaskStore` reference and a
`WidgetSnapshotStore`; debounces ~1s; on fire rebuilds → writes → `reloadAllTimelines()`. Writes
an initial snapshot in `start()`. Wired in `GSDApp` via `store.onTasksChanged = { refresher.schedule() }`.

### 4.5 GSDWidgets — the extension

`Widgets/` sources: `GSDWidgetBundle.swift` (`@main WidgetBundle`), `TodaysFocusWidget.swift`
(`StaticConfiguration`, supported families `.systemSmall`, `.systemMedium`), `TodaysFocusProvider.swift`
(`TimelineProvider` → single entry, `.never`; reads via `WidgetSnapshotStore`), `TodaysFocusEntry.swift`,
`TodaysFocusView.swift` (rows + empty state + "+N more"; `.widgetURL(DeepLinkRoute.focus.url)`).
Plus `Widgets/Info.plist` (`NSExtensionPointIdentifier = com.apple.widgetkit-extension`) and
`Widgets/GSDWidgets.entitlements` (App Group `group.dev.vinny.gsd`).

### 4.6 App — deep-link wiring

- `App/Info.plist`: add `CFBundleURLTypes` registering scheme `gsd`.
- `GSDApp`: `.onOpenURL { if let r = DeepLinkParser.route(from: $0) { route(r) } }`, mapping
  `.focus` → `navigate(to: .matrix)` (reuses the existing `ContentView.navigate(to:)`).

### 4.7 project.yml + Package.swift

- `Package.swift`: add `GSDSnapshot` library (`dependencies: ["GSDModel"]`) + `GSDSnapshotTests`.
- `project.yml`: add `GSDSnapshot` product dep to `GSD`; add `GSDWidgets` app-extension target
  (bundle id `dev.vinny.gsd.widgets`, deps GSDModel+GSDSnapshot, its own entitlements/Info.plist);
  add `{ target: GSDWidgets, embed: true }` to the `GSD` target's dependencies.

## 5. Today's Focus query

Reuses the existing `today-focus` built-in: `FilterCriteria(quadrants: [.urgentImportant],
status: .active)` via `TaskFilter.apply`. No new logic. Completed tasks excluded by `status: .active`;
sort (dueDate asc, then createdAt desc) inherited from `TaskFilter`. `limit: 8` rows; `totalCount`
carries the full count for a "+N more" affordance.

## 6. Refresh & debounce

`onTasksChanged` can fire many times during a bulk pull/import. The refresher coalesces with a ~1s
debounce (cancel-and-reschedule a `Task` with `Task.sleep`) so WidgetCenter isn't thrashed. Each fire:
build → atomic write → `reloadAllTimelines()`. An initial write happens at `start()` so a freshly
installed widget has data before the first mutation.

## 7. Deep-link + OAuth coexistence (HARD GATE)

Registering `gsd` in `CFBundleURLTypes` is what makes a custom-scheme widget link reach `.onOpenURL`.
The same scheme is used by `ASWebAuthenticationSession` for `gsd://oauth-callback`, which the session
intercepts internally. `DeepLinkParser.route(from:)` returns `nil` for `oauth-callback` so any stray
delivery is a no-op. **Both must be verified before merge:**
1. `xcrun simctl openurl <udid> gsd://focus` foregrounds the app on the Matrix.
2. A real OAuth sign-in completes end-to-end **after** the scheme is registered.

## 8. Timeline policy

`today-focus` has no time component, so the result set changes only when tasks change — never merely
because the clock advanced. `getTimeline` returns one entry with `.never`; the app's
`reloadAllTimelines()` is the sole refresh driver. No midnight rollover. `placeholder`/`getSnapshot`
return representative sample data for the gallery.

## 9. Error handling & edge cases

- **No snapshot yet (first launch):** `read()` returns `nil` → widget shows the empty state.
- **Corrupt file:** `read()` returns `nil` (try?) → empty state; next app write heals it.
- **No App-Group container** (misconfig): `write` throws `noContainer`; refresher logs and no-ops
  (never crashes the app); `read` returns `nil`.
- **App suspended:** snapshot isn't rewritten until next foreground/mutation. Accepted for 6a
  (deferred: BGTask-driven writes). The widget keeps showing the last good snapshot.

## 10. Testing

**`swift test` (GSDSnapshotTests):**
- Builder: filters to urgent+important active; excludes completed; excludes non-Q1; sorts by dueDate;
  respects `limit`; `totalCount` = full filtered count (> limit case); empty input → `.empty`-like.
- Store: round-trip via injected temp container; `read()` nil on missing file; `read()` nil on
  corrupt bytes; overwrite replaces prior snapshot.
- DeepLinkParser: `gsd://focus` → `.focus`; `gsd://oauth-callback` → nil; foreign scheme → nil;
  `DeepLinkRoute.focus.url` round-trips back to `.focus`.

**GSDStoreTests:** `onTasksChanged` fires after an observed change (mutation → callback invoked).

**Build + simctl smoke (iPhone 17 Pro + iPad Pro 13" M5):** both targets build; widget appears in
gallery and renders snapshot rows; `simctl openurl gsd://focus` routes to Matrix.

**Device live gate (user):** install on device; add widget to home screen; verify it reflects real
tasks and updates after an edit; verify real OAuth still works (§7.2).

## 11. Build vs. portal boundary

- **Sim-verifiable now (no portal work):** target builds, widget gallery, snapshot render, deep-link
  routing, App-Group file IO — all work in the simulator under automatic signing.
- **Device/portal (live gate):** register `dev.vinny.gsd.widgets` App ID in the Apple Developer
  portal, add the App-Group capability to it, regenerate provisioning. `DEVELOPMENT_TEAM=52HVJ3VDSM`
  stays committed.

## 12. Decisions & rejected alternatives

- **Precomputed snapshot (A) over widget-opens-GRDB (B):** mandated by product spec §12.2; keeps the
  widget GRDB-free and within WidgetKit's memory budget.
- **`onTasksChanged` callback over `withObservationTracking`:** the latter fires pre-commit (a
  synchronous read yields the stale value) and doesn't reliably fire during background sync; the
  callback fires post-commit on every DB change and mirrors the existing `onMutation` pattern.
- **`gsd://focus` → Matrix (not the smart-view list):** the Matrix's Q1 quadrant *is* today's focus,
  and `navigate(to: .matrix)` already exists — zero new navigation plumbing. Routing to the literal
  `today-focus` smart-view list is a deferred refinement (needs Browse/sidebar route plumbing).
- **DeepLink types in GSDSnapshot:** the widget builds the URL and the app parses it — one shared,
  unit-tested contract across the app/widget boundary.

## 13. Risks / watch-outs

- Scheme registration perturbing OAuth — mitigated by parser-ignores-callback + the §7 dual gate.
- Extension code-signing/embedding is the XcodeGen time-sink; most of it is sim-verifiable before any
  portal work, so failures surface early.
- Widget memory budget — kept safe by the GRDB-free graph and the tiny snapshot payload.
```
