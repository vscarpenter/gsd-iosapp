# iPhone Duo: fold state and vertical bars

Date: 2026-10-24. Branch: `fix/duo-fold-state-and-vertical-bars`. Source: findings 1 and 2 of the
same day's readiness review against Apple's "Designing for iPhone Duo" and "Preparing your app for
iPhone Duo".

## What the Duo changes

iPhone Duo has two displays. The outer one is compact width, so the app runs its tab root there.
The inner one is regular width, so it runs the split-view root. Closing and opening the phone swaps
roots mid-session, the same swap an iPad window makes when it resizes. The system also moves the
status bar, the toolbar, and the tab bar to a vertical strip. That happens on the outer display
and in split-view detail columns on the inner one. Vertical bars show symbols only. An item with a title and no
symbol stays horizontal, and a custom view is never placed vertically.

## Fold state

The two roots kept separate selection: `compactTab` plus the Browse path for the tab root, and
`regularSelection` for the sidebar. Opening the phone on the Dashboard tab landed on the Matrix,
and closing it from a smart view landed on whatever tab was last used. `PaletteController` now has
`carryToCompact()` and `carryToRegular()`, and `ContentView` calls them when the horizontal size
class changes. Matrix, Dashboard, Settings, Archive, and smart views map one to one. The Browse
root has no sidebar peer, since the sidebar is the browse list, so it lands on the Matrix.

The Mac widths harness is the one place a size class can cross inside a test, so
`RefreshBaseline.testSelectionSurvivesRootSwap` covers it. Dashboard chosen in the regular root
must still be on screen at 420 points. Settings chosen in the compact root must still be on screen
back at 1100. The test navigates through the View menu because a sidebar row tap does not
register on the Mac. It failed on both swaps before the mapping and passes with it.

## Bars

The "GSD · Screen" principal title is a custom view, so it can never go vertical.
`brandedNavigationTitle(_:)` is now a view modifier that reads `toolbarVerticalEdge` (iOS 27.1,
through `VerticalBarsReader`) and omits the item while the bars run vertically. The plain serif
navigation title takes its place there, left-aligned in the title row the system keeps for every
inline title. Every other device still shows the branded title; iPhone 18 Pro and iPad Air captures
confirmed it. Mac Catalyst never draws vertical bars, and its SDK does not declare the value, so
the reader reports false there without reading anything.

`SyncStatusChip` renders a `Label` in every state, so the system has a symbol for the vertical
strip and a title for the overflow menu. The pending state keeps `.titleAndIcon` so the count stays
visible on horizontal bars.

### What did not change, and why

The review assumed the text-only Edit, Done, and Empty buttons forced the horizontal row on the Duo.
Captures of the fixed build on the inner display show the row belongs to the inline navigation
title. It exists with no items in it at all, on the Dashboard for one. The text buttons sit in that
row at no extra cost. `axisBehavior(.horizontalOnly)` (iOS 27.1) moved nothing into the overflow
menu, so it came back out. The buttons keep their text on every device.

## Verification

- `cd GSDKit && swift test`: green (693 Swift Testing tests across five module runs).
- iPhone Duo (iOS 27.1), iPad Air 13-inch M4 (iOS 27.0), and Mac Catalyst build with zero
  project warnings on Xcode 27.1.
- `testSelectionSurvivesRootSwap` and `testCaptureWidths` pass on the Mac.
- Duo inner display, open pose: Matrix, Archive, a smart view, and Dashboard show the plain title
  and no branded item. The vertical strip holds Search and Show Completed.

Three checks stay with the owner because they need Device Hub's closed and folded poses:

- the outer display after the fix
- a close and reopen with Dashboard in view
- a delete followed by Undo on the closed phone
