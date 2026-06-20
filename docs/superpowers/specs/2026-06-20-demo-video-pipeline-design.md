# Repeatable Demo-Video Pipeline (iPhone · iPad · Mac) — Design

**Date:** 2026-06-20
**Status:** Approved (brainstorm) → implementing
**Supersedes/extends:** `2026-06-14-marketing-demo-video-design.md`, `2026-06-15-simulated-widget-demo-scene-design.md`

## Problem

GSD needs **clean, deterministic, re-recordable** native-app demo footage for two destinations:

1. **Marketing site** (`gsdtaskmanager.com`) — one looping, muted hero clip.
2. **App Store / Mac App Store app previews** — one per device (`iphone-6_9`, `ipad-13`, `mac`).

Footage must not be hand-recorded by tapping around: it must be driven by a scripted XCUITest over seeded data with a frozen clock, so re-recording after a UI change yields identical motion.

## What already exists (reused, not rebuilt)

The repo already has a first-generation demo harness aimed at a **captioned 16:9 marketing reel**:

- `App/Support/DemoSeed.swift` — `--demo-seed` launch arg; wipes the live `TaskStore` and seeds 10 active + 14 completed fixtures with **deterministic string IDs** (`demo-finance`, `demo-deck`, …) and sets `hasOnboarded=true`.
- `ScreenshotTests/DemoChoreography.swift` — XCUITest gated by `DEMO=1`/`DEMO_SCENE` (`TEST_RUNNER_`-prefixed env). Six short single-beat scenes (`capture`, `matrix`, `complete`, `organize`, `dashboard`, `widgets`).
- `scripts/record-demo.sh` — boots a sim, sets a 9:41 status bar, and for each scene runs the test while `simctl io recordVideo --codec h264` captures one clip per beat.
- `scripts/build-demo.sh` — ffmpeg compositor: drops each portrait clip onto a cream 16:9 backdrop with serif caption cards + optional music → `build/demo/gsd-demo-16x9.mp4`.
- `project.yml` target `GSDScreenshotTests` (`bundle.ui-testing`) + scheme `GSDScreenshots`; `.gitignore` already ignores `build/`.

**Key seams discovered:**

- `App/Support/RelativeDate.swift` does **not** read `Date()` internally — it takes a `reference:` parameter (`relativeTo: calendar.startOfDay(for: reference)`). Freezing relative due labels = feeding one injected "now" into that `reference`.
- `TaskStore(clock:)` and `GRDBTaskRepository(now:)` and `GRDBArchiveRepository(now:)` already accept injectable `@Sendable () -> Date` closures; `AnalyticsEngine(now:)` takes `now` as a parameter. No new GSDKit logic is needed to freeze time — only app-layer wiring.
- `xcodebuild` strips the `TEST_RUNNER_` prefix and injects the rest into the test-runner process, which is how `DEMO`/`DEMO_SCENE` reach the XCUITest.

## Goals

- One **continuous** 15–25 s take per platform (not six captioned beats) that flows through all demo beats and **starts and ends on the same populated-matrix frame** so the marketing hero loops cleanly.
- Per-device App Store outputs at Apple's accepted resolutions, plus a muted web hero (`mp4` + `webm` + poster).
- **Determinism:** same seed + frozen clock + forced appearance ⇒ byte-comparable motion across runs, even months apart.
- Every element the test touches is reached via an explicit `accessibilityIdentifier`.
- No video binaries committed; everything lands under gitignored `build/demos/`.

## Non-goals

- Replacing the existing captioned 16:9 reel (`build-demo.sh` stays as an optional secondary artifact).
- Fastlane `snapshot` for the marketing screenshot gallery — proposed as a **follow-up** in `DEMOS.md`, not built here.
- Recording Mac via the simulator pipeline (impossible — see Caveats).

## Architecture

```
launch args ──▶ GSDApp (demo-mode wiring)
  --demo-seed            DemoSeed.seedIfRequested(store)         (existing)
  --demo-clock <epoch>   fixed clock → TaskStore/repos + \.demoNow env   (NEW)
  --demo-appearance L|D  .preferredColorScheme override          (NEW)

scripts/record-demos.sh <iphone|ipad|mac|all> [light|dark]
   ├─ iphone/ipad: boot device sim → status_bar 9:41 → run reel-<dev> test
   │               while simctl io recordVideo → build/demos/raw/<dev>-<appearance>.mp4
   └─ mac:        run Catalyst app at fixed window → screencapture -v region
                  while reel-mac test drives it → build/demos/raw/mac.mov

ScreenshotTests/DemoChoreography.swift  (extended)
   new continuous scenes: reel-iphone · reel-ipad · reel-mac

scripts/encode.sh [--music FILE] [--loop-xfade]
   build/demos/raw/* ──▶ build/demos/out/
     marketing: gsd-demo.mp4 (H.264/yuv420p/+faststart, muted),
                gsd-demo.webm (VP9, muted), gsd-demo-poster.png
     appstore:  iphone-6_9.mp4 · ipad-13.mp4 · mac.mp4  (Apple sizes, optional music)
```

## Components

### 1. Demo-mode wiring — `App/GSDApp.swift`

Three launch args, parsed once in `init()` / the root `.task`, **all no-ops unless present** (production untouched):

- `--demo-seed` (existing) → `DemoSeed.seedIfRequested(store)`.
- `--demo-clock <epoch>` (NEW) → parse the trailing epoch-seconds value into `demoNow: Date`. When present:
  - construct `TaskStore(clock: { demoNow })`, `GRDBTaskRepository(_, now: { demoNow })`, `GRDBArchiveRepository(_, now: { demoNow })`.
  - publish `demoNow` through a new SwiftUI `EnvironmentValues.demoNow` (default `Date()`), read by views that render relative dates (`TaskCardView` → `RelativeDate(reference:)`) and by `DashboardView` → `AnalyticsEngine(now:)`.
- `--demo-appearance light|dark` (NEW) → `.preferredColorScheme(...)` applied at the `WindowGroup` root, overriding the stored `appTheme` for the run.

A tiny `DemoLaunch` helper (app-layer) parses args → `(seed: Bool, clock: Date?, appearance: ColorScheme?)`. This is the only new "logic"; it gets a focused unit-style smoke via the choreography (no app unit-test target exists).

### 2. Frozen clock / `\.demoNow` — `App/` only, demo-scoped

- New `EnvironmentValues.demoNow: Date` defaulting to `Date()`.
- `TaskCardView` passes `demoNow` as the `reference:` into `RelativeDate`. In production `demoNow == Date()`, so behavior is identical to today.
- `DashboardView` passes `demoNow` into `AnalyticsEngine(now:)`.
- The fixed epoch is chosen so seeded due dates render stable labels ("Overdue", "Today", "Tomorrow", "Next week"). Default demo epoch: **`1750420800`** (2025-06-20 12:00 UTC) — a Friday midday, stamped into `DEMOS.md` and `record-demos.sh`.

### 3. Accessibility identifiers (the bulk of the SwiftUI edits)

Add stable IDs (and report the exact final list in the PR/handoff). Keyed by the deterministic task id or quadrant rawValue so they never vary:

| Element | File | Identifier |
| --- | --- | --- |
| Capture text field | `App/Matrix/CaptureBar.swift` | `capture-field` |
| Capture quadrant chip | `App/Matrix/CaptureBar.swift` | `capture-quadrant-chip` |
| Capture details button | `App/Matrix/CaptureBar.swift` | `capture-details` |
| Matrix root (iPhone) | `App/Matrix/MatrixView.swift` | `matrix-iphone` |
| Matrix root (iPad/Mac) | `App/Matrix/MatrixGridView.swift` | `matrix-grid` |
| Quadrant section (iPhone) | `App/Matrix/QuadrantSection.swift` | `quadrant-<rawValue>` |
| Quadrant cell (iPad/Mac, drop target) | `App/Matrix/QuadrantCell.swift` | `quadrant-cell-<rawValue>` |
| Task card | `App/Matrix/TaskCardView.swift` | `task-card-<task.id>` |
| Completion disc | `App/Matrix/TaskCardView.swift` | `task-disc-<task.id>` |
| iPad swipe row (drag source) | `App/Matrix/SwipeRevealRow.swift` | `task-row-<task.id>` |
| iPad swipe-complete button | `App/Matrix/SwipeRevealRow.swift` | `task-complete-<task.id>` |
| Editor sheet | `App/Editor/TaskEditorView.swift` | `task-editor` |
| Editor save / cancel | `App/Editor/TaskEditorView.swift` | `editor-save` / `editor-cancel` |
| Palette search field | `App/Palette/CommandPaletteView.swift` | `palette-field` |
| Palette result row | `App/Palette/CommandPaletteView.swift` | `palette-row-<id>` |

Identifiers are additive; none change layout or production behavior.

### 4. Seed tweaks — `App/Support/DemoSeed.swift`

- Add **varied due dates** to the active fixtures as offsets from the frozen demo-now: one overdue, one today, one `+2d`, one `+1w` — so the matrix reads "realistic, varied due dates" and the labels are deterministic.
- Stamp `createdAt`/`updatedAt` from the injected clock (passed in, defaulting to `Date()` so non-demo callers — none today — are unaffected).
- Keep deterministic IDs and the one-completed-during-the-demo beat: leave at least one clean active Do-First card (`demo-investor`) for the on-camera swipe-to-complete + confetti.

### 5. Continuous choreography — `ScreenshotTests/DemoChoreography.swift`

Add three continuous scenes (the existing six stay). Each launches with `--demo-seed --demo-clock 1750420800 --demo-appearance <L|D>` and uses a `pause(_:)` helper (`Thread.sleep`) for deliberate **0.8–1.2 s** beats:

- **Shared open** — populated matrix → tap `capture-field`, type `Email the architect ` then ` !!` (chip recolors to Do First red) then ` #work` (tag chip appears), each with a beat → submit (`\n`) → new card lands in Do First → swipe/tap `task-disc-demo-investor` to complete → dwell on green fill + confetti.
- **`reel-iphone`** (portrait) — slow-scroll the four quadrant sections down and back → tap a card to open the editor → close → return to top scroll position.
- **`reel-ipad`** (landscape) — show the 2×2 board → **drag** `task-row-<id>` from one `quadrant-cell-*` across the boundary into another (the iPad-only reclassify gesture) → settle.
- **`reel-mac`** — press **⌘K** → palette opens (`palette-field`) → type a smart-view name ("Today's Focus") → select → view loads → back to matrix.
- **All scenes end on the populated matrix at the starting scroll offset** for a clean loop.

### 6. Recorder — `scripts/record-demos.sh` (evolved from `record-demo.sh`)

`record-demos.sh <iphone|ipad|mac|all> [light|dark]` (default appearance `light`):

- **iphone** → boot **iPhone 16 Pro Max** sim (native `1320×2868`, the `6_9` class), status-bar 9:41, run `reel-iphone` while `simctl io <udid> recordVideo --codec=h264` records → `build/demos/raw/iphone-<appearance>.mp4`. Reuses the existing background-record → run-test → `kill -INT` finalize pattern.
- **ipad** → boot **iPad Pro 13-inch (M4)** sim (native `2064×2752`), landscape, run `reel-ipad` → `build/demos/raw/ipad-<appearance>.mp4`.
- **mac** → build/run the Mac Catalyst app, pin the window to a fixed size/origin (Catalyst min is already 720×560 via `QuickActions`), start `screencapture -v -R<x,y,w,h>` (or `-l<windowid>`), run `reel-mac` against the Mac app, stop capture → `build/demos/raw/mac.mov`.

The original `record-demo.sh` is renamed via `git mv` to preserve history; the captioned-reel scenes remain callable.

### 7. Encoder — `scripts/encode.sh` (new clean tool)

Plain ffmpeg (no `drawtext` → stock Homebrew ffmpeg works). Reads `build/demos/raw/`, writes `build/demos/out/`:

**Marketing hero** (from the iPhone reel by default; `SRC=` overrides):
- `gsd-demo.mp4` — H.264, `-pix_fmt yuv420p`, `-movflags +faststart`, **audio stripped**, scaled to ~1280 px long edge.
- `gsd-demo.webm` — VP9 (`libvpx-vp9`), muted, same scale.
- `gsd-demo-poster.png` — first frame.
- `--loop-xfade` (optional) — crossfade the tail into the head (`xfade`) for a guaranteed-seamless web loop on top of the start≈end choreography.

**App Store previews** (per device, native source resolution preserved or padded to Apple's accepted frame):
- `iphone-6_9.mp4`, `ipad-13.mp4`, `mac.mp4` — H.264/HEVC, 15–30 s.
- `--music FILE` (optional) — mux a supplied track (App Store outputs only; the web hero stays muted).
- **Exact accepted resolutions are verified against Apple's current App-preview spec at build time and pinned as commented constants** in the script. Working targets: iPhone 6.9″ `1320×2868`, iPad 13″ `2064×2752`, Mac `1920×1080`/`2560×1600`.

### 8. Project + scheme — `project.yml`

Add a dedicated **`GSDDemo`** scheme (test-only, runs `GSDScreenshotTests/DemoChoreography`) so demo runs are clearly separated from the screenshot scheme. `xcodegen generate` after. `ScreenshotTests/` is glob-sourced, so the extended choreography needs no target edit.

### 9. Docs — `DEMOS.md` (repo root)

- One-command usage per device + `all`; appearance flag; the frozen-clock epoch.
- Which simulators / Mac window size are used.
- **Manual steps the owner still owns:** supply a music track; for App Store previews, the **QuickTime "New Movie Recording"** real-device fallback (UI test still drives the flow over USB) because of the simulator-rejection caveat.
- **Caveats** (below), including the Mac screen-recording permission prompt.
- **Follow-up proposal:** Fastlane `snapshot` for the marketing screenshot gallery.

## Output specs (summary)

| Output | Format | Size | Audio | Loops |
| --- | --- | --- | --- | --- |
| `gsd-demo.mp4` | H.264 yuv420p +faststart | ~1280 px long edge | muted | yes (start≈end, optional xfade) |
| `gsd-demo.webm` | VP9 | ~1280 px long edge | muted | yes |
| `gsd-demo-poster.png` | PNG | first frame | — | — |
| `iphone-6_9.mp4` | H.264/HEVC | 1320×2868 | optional music | n/a |
| `ipad-13.mp4` | H.264/HEVC | 2064×2752 | optional music | n/a |
| `mac.mp4` | H.264/HEVC | 1920×1080 / 2560×1600 | optional music | n/a |

All land in **`build/demos/out/`** (gitignored). Raw captures in `build/demos/raw/`.

## Determinism guarantees

| Source of variance | Control |
| --- | --- |
| Random task IDs | Deterministic string IDs in `DemoSeed` (existing) |
| Wall-clock "now" in store/sync | `TaskStore(clock:)` + repo `now:` fed the fixed epoch |
| Relative due labels in cards | `\.demoNow` → `RelativeDate(reference:)` |
| Dashboard trend | `AnalyticsEngine(now:)` fed `demoNow` |
| Onboarding overlay | `hasOnboarded=true` set by seed |
| Light/dark drift | `--demo-appearance` forces the scheme |
| Status bar clock/signal | `simctl status_bar override` 9:41 (iOS); cropped out on Mac |
| Animation timing | Confetti/animations kept; data/clock frozen so motion is identical |

## Caveats (surfaced to owner)

1. **Mac cannot use `simctl`.** `simctl io recordVideo` records iOS **simulators** only; Mac Catalyst is a native macOS app. The Mac path uses `screencapture -v` on the app window — which is a **real-machine capture and therefore valid for the Mac App Store preview**. It requires granting Screen Recording permission to the terminal/host once.
2. **Simulator captures may be rejected for App Store previews.** Apple expects previews captured on **real devices**. The simulator path is fine for the marketing site; for the iPhone/iPad App Store previews, `DEMOS.md` documents the QuickTime "New Movie Recording" route on a connected device with the UI test still driving the flow.
3. **App-preview resolutions are picky** and change with new device classes; `encode.sh` verifies against Apple's current spec at build time and pins the numbers with a source comment.

## Verification

- `cd GSDKit && swift test` stays green (no GSDKit changes — only injected-param usage).
- `xcodebuild` builds **both** iPhone and iPad destinations clean (Swift 6 strict concurrency).
- Run `reel-iphone` and `reel-ipad` here; eyeball `build/demos/raw/*.mp4` for correct beats, frozen labels, clean loop.
- `encode.sh` produces all six outputs; verify dimensions with `ffprobe`, confirm the web hero is muted and `+faststart`.
- **Mac is owner-run** (the sandbox can't drive a real Mac GUI session with screen-recording permission). The exact command is provided in `DEMOS.md`.

## Follow-ups

- Fastlane `snapshot` for the marketing-site screenshot gallery (multi-locale, multi-device stills) — separate spec.
- Optionally fold the continuous reels into the captioned 16:9 reel if a longer narrated cut is wanted later.
