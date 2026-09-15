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
