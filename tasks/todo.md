# iPhone Duo: matrix rows in landscape and a large widget (2026-10-25)

Branch: `fix/duo-matrix-rows-and-large-widget` off `main` (`62f868f`). Decisions: `docs/2026-10-25-iphone-duo-matrix-rows-and-large-widget.md`.
Source: findings 6 and 7 of the iPhone Duo, iOS 27, and new-device readiness review of 2026-10-24.

- [x] Evidence: content-sized cells (220 pt minimum) in one scrolling page; widget families small and medium; snapshot limit 8
- [x] Finding 6: `MatrixGridView` pins two rows below 760 pt of viewport height; `QuadrantCell(pinnedHeight:)` scrolls its own list
- [x] Finding 7: `systemLarge` added; large shows eight rows at subheadline size
- [x] Finding 6 guard: the pinned cell's inner scroll view takes `scrollBounceBehavior(.basedOnSize)`, so a short list leaves the pull to the page's refresh
- [x] Verify: iPad mini (iOS 27.0, landscape) matrix before (`build/screens/duo-matrix-before`, second row below the fold) and after (`duo-matrix-after`, full 2x2 in view); iPad Air unchanged (`duo-matrix-after-air`, 0 px dark and 82 px light against `editor-bar`); `swift test` 283 green; `xcodegen generate` no project change; iPhone 18 Pro, iPad Air 13-inch (M4), and Mac Catalyst builds clean
- [x] Docs, memory; three commits on this branch (finding 6, finding 7, docs)
- [ ] Owner's go-ahead for push and PR

## Resuming From Here
- Done: both fixes, the bounce guard, every verification run, the decision record, and memory; committed on this branch.
- Next: the owner gates (push and PR), then the owner's Device Hub look at the open Duo in landscape and the large widget on a Home Screen.
- Blockers: the Duo inner display and the widget render are owner-checked; the iPad mini walk misses the sidebar's Archive and Settings rows (harness, out of scope).
- Assumptions: a 760 pt threshold; the large widget shows the snapshot's eight rows; no snapshot cap change; pull-to-refresh on a pinned cell is reasoned from Apple's bounce default, not measured.

# iPhone Duo: upside-down portrait (2026-10-25)

Branch: `fix/duo-upside-down` off `main` (`67d28d0`). Decisions: `docs/2026-10-25-iphone-duo-upside-down.md`.
Source: finding 5 of the iPhone Duo, iOS 27, and new-device readiness review of 2026-10-24.

- [x] Evidence: iPhone list has three orientations, iPad list four; nothing in the app reads orientation
- [x] Fix: `UIInterfaceOrientationPortraitUpsideDown` added to the iPhone list in `project.yml`; `xcodegen generate`; plist checked (only the spec and the plist changed)
- [x] Verify: Duo, iPad, and Mac Catalyst builds clean; launched on the Duo; `swift test` 283 green; probe: iPhone 18 Pro refuses upside-down with the list, the Duo simulator ignores programmatic turns (owner-run)
- [x] Docs, lessons, memory; committed on this branch
- [ ] Owner's go-ahead for push and PR

## Resuming From Here
- Done: the change, its verification, the probe, and the decision record, committed on this branch.
- Next: the owner gates (push and PR), then the owner's Device Hub turn on `main` first; close the PR if the open phone already follows.
- Blockers: the Duo simulator ignores programmatic turns, so the only Duo measurement is the owner's.
- Assumptions: shipped under stated doubt (Apple says the inner display ignores the list); the one certain effect is on Home-button iPhones.

# DemoSeed isolation (2026-10-25)

Branch: `fix/demo-seed-isolation`, in the worktree `../.worktrees/gsd-iosapp-demo-seed` (another
session owns the main checkout). Decisions: `docs/2026-10-25-demo-seed-isolation.md`. Source: the
2026-10-24 account wipe by the Mac widths harness; the tasks were restored from the Mac's Trash
the next day.

- [x] Red: `DemoFixturesTests` fails to compile on the missing type (refuses a store with a real task, nothing deleted or queued; seeds 24 into an empty store; a second seed leaves 24)
- [x] Green: `GSDStore/DemoFixtures.swift` holds the fixtures and the guarded `seed(into:now:)`; `App/Support/DemoSeed.swift` is the launch wrapper
- [x] `GSDApp.init`: a `--demo-seed` launch opens `AppDatabase.inMemory()` and uses `SignedOutTokenStore`
- [x] `swift test`: 283 tests, 31 suites green
- [x] `xcodegen generate`; iPhone 18 Pro, iPad Air 13-inch (M4), and Mac Catalyst builds pass
- [x] Smoke: `RefreshBaseline.testCaptureEveryScreen` on the iPhone 17 Pro simulator, light and dark, 14 screens each, both passed; the simulator's on-disk `gsd.sqlite` kept its Sept 7 timestamp, so the demo launch never opened it
- [x] Docs and lessons written; code committed as `32063ed`, docs in the commit after it
- [x] Pushed; PR #30 open against main
- [x] Review of PR #30 (12 findings) resolved 2026-10-25: `HarnessLaunch.isIsolated` (any `--demo-` argument) swaps every shared seam (defaults suite, reminders, Spotlight, share outbox, widget snapshot); the seed refuses any non-empty store and lost its delete loop; failures are loud; the legacy screenshot runner launches isolated

## Resuming From Here
- Done: tests, package type, app wiring, three builds, the simulator smoke, decision doc, lesson, both commits, the main merge, and the review fixes.
- Next: merge PR #30, then remove the worktree (`git worktree remove ../.worktrees/gsd-iosapp-demo-seed`).
- Blockers: none; the merge is the owner's call.
- Assumptions: the guard reads live tasks only (the set the seed deletes); the Mac harness is not re-run on this Mac until the owner chooses to.

# iPhone Duo: Field Guide shortcuts follow the width (2026-10-25)

Branch: `fix/duo-help-shortcuts` off `main` (`316cb8c`). Decisions: `docs/2026-10-25-iphone-duo-help-shortcuts.md`.
Source: finding 4 of the iPhone Duo, iOS 27, and new-device readiness review of 2026-10-24.

- [x] Evidence: one idiom check in the app (`HelpView.swift:289`); the sheet is presented once, from `ContentView`; the editor already takes `compactPresenter`
- [x] Fix: `HelpView(compactPresenter:)`, shortcuts shown on a regular presenter (the Mac always); `ContentView` passes its size class
- [x] Test: `testHelpShortcutsFollowTheRootWidth` (green by construction on iPhone and iPad; red only on the open Duo, which the owner runs)
- [x] Verify: `swift test` 283 green; iOS simulator and Mac Catalyst builds clean; the test passes on iPhone 18 Pro (hidden) and iPad Air (shown)
- [x] Docs, memory; committed on this branch
- [ ] Owner's go-ahead for push and PR

## Resuming From Here
- Done: fix, test, docs, and verification; committed on this branch.
- Next: the owner gates (push and PR), then the owner's run of the test on the open Duo.
- Blockers: the red case needs the open Duo (owner).
- Assumptions: one rule (the presenter's width); no connected-keyboard check.

# iPhone Duo: the editor bar on the outer display (2026-10-25)

Branch: `fix/duo-editor-bar`, stacked on `fix/duo-screenshot-harness` (PR #27 was still open on GitHub when this started; rebase onto `main` once it merges). Decisions: `docs/2026-10-25-iphone-duo-editor-bar.md`.
Source: the new finding in PR #27. Once the task editor's form scrolls on the Duo's outer display, the sheet's title, Cancel, and Save vanish.

- [x] Evidence: every failure dump shows the sheet's `NavigationBar` keeping its frame with no children; the iOS 27.1 SwiftUI interface and Apple's docs read (toolbar minimization, vertical bars)
- [x] Red: `ReleaseReadinessTests.testEditorBarSurvivesScroll` fails on the closed Duo (title, Cancel, and Save gone after one scroll; back after scrolling up) and passes on iPhone 18 Pro
- [x] Root cause confirmed by a one-variable test: iOS 27 bar minimization on scroll; `toolbarMinimizationBehavior(.never, for: .navigationBar)` alone turned the Duo test green
- [x] Fix in `TaskEditorView`, guarded for iOS 27; the test is green on the Duo and still green on iPhone 18 Pro
- [x] Verify: `swift test` 283 green; iPhone, iPad, and Mac Catalyst builds clean; the `duo` walk 14 + 14, the iPhone walk 14 + 14, and the iPad walk 12 + 12, all with zero failures
- [x] Docs, lessons, memory; committed on this branch
- [ ] Owner's go-ahead for push and PR (rebase onto `main` once PR #27 merges)

## Resuming From Here
- Done: root cause confirmed, fix applied and committed, every verification run green.
- Next: on the owner's go-ahead, rebase onto `main` (after PR #27 merges) and open the PR.
- Blockers: the owner gates only (push and PR; the PR #27 merge for the rebase).
- Assumptions: the fix lives in `TaskEditorView` only; the empty vertical strip the sheet reserves on the outer display is a separate follow-up.

# iPhone Duo: screenshot harness (2026-10-25)

Branch: `fix/duo-screenshot-harness`. Decisions: `docs/2026-10-25-iphone-duo-screenshot-harness.md`.
Source: finding 3 of the iPhone Duo, iOS 27, and new-device readiness review of 2026-10-24.
Design approved: `duo` (headless, closed pose, outer display) and `duo-open` (owner unfolds in
Device Hub, inner display, portrait); the empty editor bar seen on the outer display is reported,
not fixed here, if it reproduces on a fresh build.

- [x] Red: the unchanged walk on the closed Duo: 13 failures (no `tabBars` element, idiom picks the wrong walk, editor drag scrolls an already large sheet)
- [x] `RefreshBaseline`: pick the walk by what is on screen; `selectTab` falls back to labeled buttons; `goBack` matches `BackButton`; drag the grabber only when the sheet is not already expanded; drag the sheet away if Cancel is missing
- [x] `capture-screens.sh`: `duo` reboots into the closed pose; `duo-open` waits for the inner display (variation, not brightness); display UUIDs discovered per boot; every Duo PNG pixel-verified (size, no alpha); iPad default moved to the 27.0 iPad Air 13-inch (M4)
- [x] Green: fresh build, `duo` light and dark clean (14 + 14, verified 1398x2034, no alpha); iPhone 18 Pro 14 + 14 and iPad Air 12 + 12, zero failures
- [x] Editor bar re-checked on the fresh build: reproduced (scrolling the form empties the sheet's bar on the outer display); reported in the doc, fix deferred to a follow-up
- [ ] `duo-open`: inner display captured at 2007x2853 after the owner unfolds (the first run waited an hour with the phone closed and timed out, as designed)
- [x] Docs, lessons, memory; harness committed as `c2110ae`
- [ ] Owner's go-ahead for push and PR

## Resuming From Here
- Done: harness committed (`c2110ae`); outer display, iPhone 18 Pro, and iPad Air walks are green; the editor-bar finding is in the doc; `duo-open` ran once with `DUO_WAIT=3600` and timed out because the phone stayed closed.
- Next: when the owner opens the Duo in Device Hub (portrait), re-run `bash scripts/capture-screens.sh duo-harness duo-open`, check for 2007x2853 PNGs with no alpha, and record the result in the doc. Then push and open the PR on the owner's go-ahead.
- Blockers: the inner-display walk and the push both wait for the owner.
- Assumptions: portrait for the inner display; the raw captures are the App Store Connect set, composites stay in the launch kit.

# iPhone Duo: fold state and vertical bars (2026-10-24)

Branch: `fix/duo-fold-state-and-vertical-bars`. Decisions: `docs/2026-10-24-iphone-duo-fold-and-bars.md`.
Source: findings 1 and 2 of the iPhone Duo, iOS 27, and new-device readiness review of the same day.

- [x] Red: `RefreshBaseline.testSelectionSurvivesRootSwap` (Mac widths harness) fails on both swaps
- [x] Green: `PaletteController.carryToCompact()` and `carryToRegular()`, applied from `ContentView` on a size-class change (`04b4a21`)
- [x] Branded title omitted on vertical bars: `brandedNavigationTitle(_:)` is a view modifier over `VerticalBarsReader`
- [x] `SyncStatusChip` renders a `Label` in every state
- [x] `axisBehavior(.horizontalOnly)` tried on the text buttons and removed: the title row exists regardless, and nothing overflowed
- [x] Verify: `swift test`, iPhone Duo, iPad, and Mac Catalyst builds, both Mac widths tests, Duo inner-display captures
- [x] Commit the bars change (`966b90b`); push and the PR wait for the owner

## Resuming From Here
- Done: both fixes are in; the root-swap test is green; the Duo inner display confirms the bars change; iPhone 18 Pro and iPad Air still show the branded title.
- Next: merged as PR #26 (`2d9de92`, 2026-10-25). The Device Hub closed-pose checks (close and reopen with Dashboard in view; delete, then Undo) are still owner-owed.
- Blockers: the closed pose cannot be driven from this shell (no Accessibility for Rex Server; the owner chose to set poses by hand).
- Assumptions: the Browse root maps to the Matrix on opening; text buttons keep their text everywhere.

# Parity port: Apple sync safety, editor merge, and archive sync (2026-10-13)

Source of truth: the claude.ai Project "GSD Task Manager Project", `parity/backlog.md`.
Written without a Swift toolchain (the build session couldn't reach download.swift.org),
reviewed by hand, then tested on a Mac before each push.

- [x] B-04, B-05, B-06: merged as #19 (`4e4963e`)
- [x] B-03: merged as #20 (`3976a05`)
- [ ] B-43: `fix/archive-deletes-server-copy`. Archiving now deletes the server copy, as on web
  and Android. Decision: `docs/2026-10-13-archive-sync-parity.md`

## Resuming From Here
- [ ] On `fix/archive-deletes-server-copy`: `cd GSDKit && swift test`, build iPhone and iPad, push, open the PR
- [ ] After merge, mark B-43 fixed in `parity/backlog.md`
- Follow-ups logged in the backlog, not started: B-42 (edit beats a queued delete), B-44
  (far-future clamp), B-45 (index after delete), D-9, D-10

# iOS 27 / macOS 27 refresh (3.0.0)

Branch: `feat/ios27-refresh`. Brief: `../design_handoff_ios27_refresh/gsd-iosapp.md`
(source review: `iOS 27 Refresh Review.dc.html` beside it). Stance: selective Liquid
Glass. System chrome may take glass; `surfaceCard()`, quadrant washes, sheet content, and
the matrix stay opaque. No token changes, no contract changes.

Prior state: the product video shipped on `video/product-demo` (PR #17 open); its plan
lives in git history at `388d7ef`.

## Phase 0: rebuild and baseline (blocking)
- [x] Toolchain: Xcode 27.0 (27A266a), Swift 6.4, iOS 27.0 SDK and simulator runtime
- [x] `project.yml`: 3.0.0 (34). `SWIFT_VERSION` stays "6.0" (a language mode; the compiler rejects 6.4)
- [x] `cd GSDKit && swift test` baseline green (271 Swift Testing tests, 30 suites)
- [x] Build iPhone, iPad, and Catalyst on the 27 SDK (zero errors, zero project warnings, no source change)
- [x] @State macro sweep: nothing to fix; the macro coexists with the wrapper and every `State(initialValue:)` site compiles
- [x] Scene lifecycle audit: scene-based already; removed the dead `AppDelegate.performActionFor` (pre-scene path)
- [x] Baseline screenshots on all three targets (light and dark): iPhone 14/14, iPad 11/12, Mac 3 (matrix, smart view, dashboard)
- [x] Commit `f5c7fb4`

## Phase 1: Liquid Glass, selectively
- [x] `AppAppearance.configure()`: title attributes only; appearance objects dropped (pixel-identical on iPhone)
- [x] Glass slider extremes: simulator Settings has no Display page; analytic AA check in the doc, `GlassSetting.swift` for the owner's device pass
- [x] `PRODUCT.md`: principle 6, editorial surfaces never take glass
- [x] Catalyst pass: selected-row rule unified, sidebar keeps the system material (experiment in the phase2 captures), menu commands unchanged
- [x] Sidebar: Matrix row carries the four-pigment mark; selected row defers to `.primary` (iPad ink pill, Mac neutral fill)
- [x] Commit `e93efdb`

## Phase 2: new SwiftUI APIs
- [x] `.swipeActions` on the iPad matrix cards inside `.swipeActionsContainer()` (iOS 27); `SwipeRevealRow` stays as the iOS 26 fallback because the floor stays at 26
- [x] `reorderContainer` evaluated and rejected (no stored order; a positional field is a three-repo contract change); see the doc
- [x] Toolbar `visibilityPriority` (search high, Show Completed and Edit low) plus `tabBarMinimizeBehavior(.onScrollDown)`
- [x] Commit (with Phase 3.1, one unit)

## Phase 3: resizable iPhone app
- [x] Root swap: selection and Browse path already shared; the editor sheet moved to the root (`PaletteController.editor`), five per-surface sheets removed
- [x] Fixed geometry sweep: undo window as the tab bar accessory on iOS 26.1+ (`UndoDeleteController`), trend picker `fixedSize`; capture bar, detents, rings already fluid
- [ ] Three window widths plus the mid-session swap on the Mac (`--demo-window` hook, `testCaptureWidths`): code in, run blocked by the locked Mac session
- [ ] Commit

## Phase 4: icon and widget
- [x] Layered app icon `App/AppIcon.icon` (check group first, opaque tiles, dark specializations); live on the iPad Home Screen in both appearances; Clear/Tinted need a device look
- [x] Today's Focus: due-state shape markers (filled overdue, half today, outline later), `widgetRenderingMode`-aware tint; sample rows carry due states
- [x] Catalyst menu bar and Mac widget: not applicable (no status item; the widget extension is iOS only)
- [ ] Commit

## Verification gates (every phase)
- `cd GSDKit && swift test`
- `xcodegen generate`, then build iPhone, iPad, and Catalyst
- Screenshot comparison against the Phase 0 baseline for every touched screen

## Resuming from here
- Done: Phases 0, 1, 2, 3.1 committed (`f5c7fb4`, `e93efdb`, `83887f4`); Phase 3b (undo accessory, geometry, Mac width hook) and Phase 4 (icon, widget) applied and compiling on all three targets; `whatsnew.txt` drafted for 3.0.0
- Next: review the `phase3` captures (iPhone, iPad, widget demo), commit Phase 3b then Phase 4, final three-target build, handoff
- Blocked: Mac captures (`phase2 mac`, `phase3 mac`, `widths`) need an unlocked GUI session; the glass slider extremes need a device
- Assumptions: `xcode-select` points at the Command Line Tools on this machine; every
  xcodebuild call sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`


# Local App Store readiness pass (2026-10-17)

Scope: inspect release configuration and existing behavior, fix confirmed issues, verify locally.
Preserve architecture, identity, capabilities, and privacy declarations. No commits or uploads.

- [x] Discover project: shared SwiftUI iOS app with Mac Catalyst, GRDB 7.10.0, optional PocketBase sync.
- [x] Baseline: 281 package tests; iOS Simulator and Catalyst Release builds.
- [x] Reproduce backup-validation/counting bug with two failing regression tests, then fix.
- [x] Full suite after fix: 283 tests, 31 suites.
- [x] First-launch capture, cancellation, editing, and relaunch persistence: iPhone and iPad Release UI tests.
- [x] Confirm duplicate View menus at runtime; consolidate commands into the system menu.
- [x] Unsigned iOS device archive; inspect versions, device families, extensions, privacy manifests.
- [x] Expanded iPhone lifecycle: iOS 27.0 and 26.5; final-source iOS 26.5 rerun passed.
- [x] Final unsigned iOS device and Catalyst archives, and final 283-test package suite.
- [x] Dark iPhone screen walk: 14 captures; inspected editor/dashboard/settings/capture.
- [x] Stop the celebration timeline after its burst and when Reduce Motion is enabled.
- [x] Closed October 18: original iPad context-menu lifecycle passed in about five minutes; XCTest idle waits caused the apparent stall.
- [x] Save final evidence ledger with blockers and exact owner validation steps.

Resuming from here: see docs/2026-10-17-release-readiness.md and build/release-readiness/.
Signed Catalyst Debug/Release builds and normal matrix startup were verified on October 18; see the evidence ledger for runtime coverage and remaining distribution gates.
The live privacy policy omits optional third-party shared-link title requests; owner review is required.


# Release-readiness follow-up (2026-10-18)

Owner is handling certificate/profile reconciliation. Continue locally without commits or publication.

- [x] Prepare shared-link title disclosure in the marketing site's privacy policy; static build and edited-file lint pass. Preserve its existing bun.lock and gallery work.
- [x] Diagnose the iPad context-menu automation wait with process samples; original UI passes. Discard ineffective preview experiment.
- [x] Fix reproduced large-text editor crowding: expanded presentation, one-column quadrant picker, and UI regression.
- [x] Final accessibility audits pass after hiding decorative quadrant heading icons flagged on iOS 26.5; iOS 27 iPhone/iPad largest-text reruns also pass.
- [x] Reverify affected app builds/unsigned archives, 283 package tests, and update the evidence ledger.
- [x] Owner resolved certificate profiles; signed Catalyst Debug/Release builds, signatures, matrix startup/relaunch, menus, and Delete/Undo verified.
- [x] Owner authorized committing readiness fixes and opening a PR on October 18.
- Account/provider flows, physical-device VoiceOver, distribution validation, and App Store Connect state remain separate checks.
