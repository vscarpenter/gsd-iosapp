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
- [ ] Glass slider extremes (ultra-clear and tinted), light and dark: ink and `Surface.tint` hold AA on Matrix, Browse, Dashboard toolbars, the tab bar, sheet chrome
- [x] `PRODUCT.md`: principle 6, editorial surfaces never take glass
- [ ] Catalyst pass: sidebar edge to edge, serif large titles, `GSDMenuCommands.swift`, remove Tahoe-era workarounds that fight the system
- [x] Sidebar: Matrix row carries the four-pigment mark; selected row defers to `.primary` (iPad ink pill, Mac neutral fill)
- [ ] Commit

## Phase 2: new SwiftUI APIs
- [ ] Replace `SwipeRevealRow` with `.swipeActions` on the iPad matrix cards (inside `.swipeActionsContainer()`), wired through `TaskActions`; VoiceOver actions and RTL parity; retire the file
- [ ] Evaluate `reorderContainer` for in-quadrant order and smart-view list order; cross-quadrant drag semantics unchanged
- [ ] Toolbar `visibilityPriority` on the Matrix toolbar so the capture bar stays the hero on compact
- [ ] Commit

## Phase 3: resizable iPhone app
- [ ] TabView and NavigationSplitView swap mid-session: selection, open sheets, Browse push path, `pendingEditor`
- [ ] Fixed geometry sweep: undo toast 72pt, capture-bar width, sheet detents, rings grid
- [ ] Two or three intermediate widths in `ScreenshotTests/`
- [ ] Commit

## Phase 4: icon and widget
- [ ] Layered app icon (Icon Composer `.icon`); monochrome variant survives on shape alone
- [ ] Today's Focus under tinted and clear rendering: shape identity per quadrant, `widgetRenderingMode`
- [ ] Catalyst menu bar and Mac widget check after the icon rebuild
- [ ] Commit

## Verification gates (every phase)
- `cd GSDKit && swift test`
- `xcodegen generate`, then build iPhone, iPad, and Catalyst
- Screenshot comparison against the Phase 0 baseline for every touched screen

## Resuming from here
- Done: Phase 0 toolchain, version bump, three-target build, State and lifecycle sweeps, simulator baselines
- Next: Mac baseline (rerunning), remove the dead AppDelegate method, commit Phase 0, start Phase 1
- Found by the baseline: iPad sidebar selected row is an opaque ink pill on the 27 SDK (label unreadable); fix in Phase 1
- Blockers: none
- Assumptions: `xcode-select` points at the Command Line Tools on this machine; every
  xcodebuild call sets `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`
