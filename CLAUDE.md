# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

GSD ("Get Stuff Done") is a native SwiftUI rebuild of an offline-first, privacy-first Eisenhower-matrix task manager for iPhone and iPad. Product intent and design principles live in `PRODUCT.md`; the behavior authority is the root product spec `spec.md`. **Project coding standards are in `coding-standards.md` (the full agentic reference) — this file covers only what's project-specific and not discoverable by reading the tree.**

## Commands

The fast feedback loop is the Swift package, not the app. Pure logic (model, store, sync, snapshot) is unit-tested with no simulator and no backend:

```bash
cd GSDKit && swift test                    # full suite, sub-second
cd GSDKit && swift test --filter LWWTests  # a single test type / case
```

The Xcode project is **generated** — regenerate it after any change to `project.yml`, then build for a simulator:

```bash
xcodegen generate                          # project.yml -> GSD.xcodeproj (also writes App/Info.plist)
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
# iPad: -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
# Mac Catalyst (the app also ships on Mac); CODE_SIGNING_ALLOWED=NO avoids minting a
# provisioning profile just to verify a local build compiles + embeds extensions:
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO build
```

iPhone and iPad are co-equal targets — build both before considering UI work done. A local Catalyst build verifies compilation + `.appex` embedding; share-extension *runtime* behavior (Share-menu registration, what Safari hands the extension) is owner-verified with a signed build in /Applications — Catalyst does NOT honor `WebPage` activation / JS preprocessing, and `scenePhase .active` is unreliable there (see project memory). Per-phase verification has historically been a `simctl` install-launch-screenshot smoke test (the App target has no unit-test target; app-layer glue is verified by build + smoke, the logic it calls is verified by `swift test`).

**Lint:** no linter is configured in-repo (no `.swiftlint.yml` / `.swiftformat`); `swift test` plus a clean `xcodebuild` are the gates.

Deployment target is iOS 26.0; Swift language version 6.0 (the SwiftPM manifest needs `swift-tools-version: 6.2` for the `.iOS(.v26)` platform enum). Swift 6 strict concurrency is on — expect `Sendable` / actor-isolation diagnostics, not warnings to wave through.

## Architecture

A layered SwiftPM package (`GSDKit/`) holds all testable logic; the app and two extensions are thin SwiftUI/host shells on top. **The dependency direction is the design** — keep it intact:

- **`GSDModel`** — pure domain, **zero dependencies** (manifest-enforced; never `import GRDB` here). `Task`, `Quadrant`, `CaptureParser`, `RecurrenceEngine`, `DependencyGraph`, `TaskFilter`/`FilterCriteria`, `TaskValidator`, analytics, import/export. Also home to the `AppGroup.id` constant (single source of truth).
- **`GSDStore`** — GRDB persistence (depends on GSDModel + GRDB). `AppDatabase` + numbered migrations (v1–v5), per-entity `*Repository` types over `ValueObservation`→`AsyncStream`, and the `@MainActor @Observable TaskStore` — the **single mutation path** for tasks, which stamps `updatedAt` via an injected clock and enqueues to the sync queue. Embedded `tags`/`subtasks`/`dependencies`/`timeEntries` are stored as **JSON columns** (matching the web Dexie + PocketBase shapes), not child tables.
- **`GSDSync`** — Foundation-only PocketBase REST + SSE sync (depends on GSDModel + GSDStore). The core is a **pure `actor SyncEngine`** (pull / push / deletion-reconcile / last-write-wins, fully unit-tested). Plus OAuth2-PKCE auth, JWT, and the wire mappers.
- **`GSDSnapshot`** — the **GRDB-free app↔extension contract** (depends on GSDModel *only*). `WidgetSnapshot` + atomic App-Group store, the Share-Extension outbox/`ShareInbox`, and `gsd://` `DeepLinkParser`. This is why the extensions can share logic without pulling the database into their process.

The **App layer** (`App/`) is SwiftUI, organized by feature folder (`Matrix/`, `Editor/`, `Browse/`, `Dashboard/`, `Sync/`, `Auth/`, …). Two pieces tie it together:

- **`GSDApp.swift`** constructs and wires every store/engine/coordinator in `init()` (one `AppDatabase`, shared repos handed to both `TaskStore` and `SyncEngine` so a pulled write reaches the UI observer and a local enqueue reaches the sync drain). `BGTaskScheduler` handlers are registered here because that must happen pre-launch.
- **`ContentView.swift`** is the adaptive root: iPhone = `TabView` (Matrix · Browse · Dashboard · Settings); iPad = `NavigationSplitView` (sidebar → detail). It also hosts the ⌘K command palette and `onOpenURL` deep-link routing.
- **`App/Sync/SyncCoordinator.swift`** — an app-layer `@MainActor @Observable` that owns *when* sync fires (cadence timer, `NWPathMonitor`, scenePhase, debounced post-mutation push, SSE lifecycle) and the status surface. The pure `SyncEngine` stays the tested core; this is the untestable glue, deliberately separated.

**Extensions** (`Widgets/`, `ShareExtension/`) are GRDB-free, embedded in the app bundle, and talk to it only through `GSDSnapshot` + the shared App Group.

## Project-specific gotchas

- **`project.yml` is the source of truth; `App/Info.plist` and `project.pbxproj` are generated.** Never hand-edit the plist or pbxproj — XcodeGen overwrites them. Plist properties (URL schemes, `NSExtension` dicts, launch screen, background modes) belong in `project.yml` under `info.properties`. Run `xcodegen generate` after editing it.
- **Two `Task` types.** `GSDModel.Task` (the domain entity) shadows Swift Concurrency's `Task`. In the app and anywhere both are in scope, the concurrency one is written `_Concurrency.Task`.
- **App Group `group.dev.vinny.gsd`** is the shared container across app + both extensions (bundle id `dev.vinny.gsd`, widgets `.widgets`, share `.share`). App-Group `UserDefaults` is reached via `.shared`.
- **`DEVELOPMENT_TEAM = 52HVJ3VDSM` is intentionally committed** in `project.yml` (applies to all targets). Do not strip it — it's the owner's real Apple Developer team and earlier "no team in commits" guidance was reversed.
- **Offline-first is a correctness constraint, not a preference.** The app must be fully usable with no account and no network; sync is opt-in. UI copy must not imply data leaves the device when it doesn't.

## Where things live (non-standard layout)

State is **not** in the usual `tasks/` directory:

- `PRODUCT.md` — product purpose, brand, design principles, accessibility targets.
- `spec.md` (repo root) — the full behavior spec / authority.
- `docs/specs/` — per-phase specs; `docs/superpowers/plans/` — per-phase implementation plans. Each phase runs its own spec→plan→execute cycle.
- `.claude/decisions/*.log` — per-file write-rationale logs (one per source file); consult when you need the "why" behind an existing file.

Current phase status and roadmap live in git history and Claude's project memory, not here — don't pin transient state (phase numbers, test counts) into this file.
