# Implementation notes: iOS 27 refresh

Tactical deviations from the brief, with the reason. Distill into `tasks/lessons.md` at handoff.

## 2026-09-15

- The brief says to update `SWIFT_VERSION` to 6.4. That build setting is the language
  mode, and the Swift 6.4 compiler accepts only 4, 4.2, 5, and 6 there. The setting stays
  at "6.0" with a comment in `project.yml` explaining why. Xcode 27 supplies the 6.4
  compiler on its own.
- `CLAUDE.md` points at an `openwiki/` directory that does not exist in the tree. Treated
  as a stale claim; nothing to read there.
- `xcode-select` on this machine points at the Command Line Tools, so `xcodebuild` and
  `simctl` fail without `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Every
  build and simulator command in this session sets it.
- The SDK interface confirms the brief's APIs: `swipeActions` on any view plus
  `swipeActionsContainer()` (iOS 27, macOS 27), `reorderContainer(for:move:)` with
  `.reorderable()` on `ForEach` (iOS 27, macOS 27), and `visibilityPriority(_:)` on toolbar
  content (iOS 27, macOS 26.1). `@State` now exists as both a property wrapper and an
  attached macro in SwiftUICore.
- Two `xcodebuild test` sessions must never share a simulator: a second session kills the
  first runner mid-walk ("Test crashed with signal kill"). `capture-screens.sh` runs light then
  dark on one device before moving to the next, so a device is free only after its dark pass.
- The Mac Catalyst UI-test runner is sandboxed (read-only outside its container). The baseline
  walk writes to the runner's temporary directory on the Mac and the script copies the PNGs out.
- The 27 SDK changed the sidebar selection fill in both directions: opaque app tint (ink) on
  iPad, where the old code kept ink text (unreadable), and a neutral fill on macOS 27 while the
  sidebar is unfocused, where the old Catalyst-only "paper text" rule painted white on light.
  The selected row now uses `.primary`, which follows whichever fill the system paints.
- Dropping the `UINavigationBarAppearance` and `UITabBarAppearance` objects changed nothing
  visible on the 27 SDK (iPhone light screens pixel-identical to the baseline) and the serif
  titles still render from the legacy attribute proxies. Kept the simpler code.
- `visibilityPriority` on toolbar items controls overflow order when the toolbar runs out of
  room; the scroll-minimizing behavior the brief describes belongs to the tab bar
  (`tabBarMinimizeBehavior`, iOS 26). Both are applied in Phase 2.
- Today's Focus is the `today-focus` smart view, which is Do First only, so the widget has no
  per-row quadrant to mark. The shape identity encodes due state (overdue, due today, later)
  instead, which is what changes row to row.
