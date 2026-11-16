# The matrix: narrower columns on iPad

Date: 2026-11-15. Branch: `fix/ipad-matrix-columns`. Follows
`docs/2026-11-05-matrix-adaptive-columns.md`.

## Why

The owner reported that the Columns toggle works on the Mac and does nothing on the iPad. Two
screenshots from a 13-inch iPad Pro in landscape, sidebar open, showed the toggle on and off over
the same one-column matrix.

The toggle worked, and the rule gave it nothing to do. Each card in the screenshot measures 480
points, the quadrant's full content width. A second column needed 576: two 280-point cards and a
16-point gap. The November 5 record predicted this case ("about 480 points, so it stays at one
column") and left the toggle enabled there. A control that changes nothing in the device's default
state reads as broken.

That record also overstated where iPad columns appear. An 11-inch iPad gives a quadrant at most
557 points with the sidebar hidden, so at 280 it never reached two columns. Only 13-inch iPads
did, and only with the sidebar hidden.

The Mac was never affected. It draws the iPad layout at 77 percent scale, so a window gives each
quadrant about 1.3 times the app points.

## What ships

The owner chose narrower iPad columns on 2026-11-15, over keeping 280 and only dimming the toggle.

- The iPad's minimum card width drops from 280 points to 227. The Mac stays at 280.
- A card narrower than 280 points in columns hides its `⋯` button, and the title takes the 54
  points. The same menu stays on long-press and right-click, swipe actions and tap to edit don't
  change, and VoiceOver keeps its custom actions.
- The Columns toggle dims when one column is all that fits. That replaces the November 5 decision
  to leave it enabled.

The owner approved 228. The shipped number is 227, because 228 came from arithmetic that assumed
a 320-point sidebar. The sidebar is 320 points on the owner's iPad and on the iOS 27 simulator,
and 330 on the iOS 26.5 simulator. A 1,366-point iPad on iOS 26.5 has a 470-point quadrant, which
fits two 227-point cards and misses two 228-point cards by 2 points.

Three more changes keep the narrow card working. The first two apply to the iOS 26 swipe row
only, because iOS 27 uses the system's swipe actions.

- A full swipe completed a task at half the row's width. On a 227-point card that is 114 points,
  and an ordinary swipe passes it. A narrow card now keeps the 280-point card's 140.
- An escalating task opens three 84-point trailing buttons, 252 points, which covered the whole
  card and left nothing to tap closed. The buttons now shrink to leave a 44-point strip of card.
- A card was a button for VoiceOver only because its `⋯` child was one. The matrix rows now add
  the trait themselves.

## Rules

- Columns: `max(1, floor((width + 16) / (minimum + 16)))`, where the minimum is 227 on iPad and
  280 on the Mac. Two iPad columns need 470 points, and three need 713.
- A card's width is `(width − 16 × (columns − 1)) / columns`. In two or more columns it keeps the
  `⋯` button at 280 points and up. A one-column list always keeps it.
- A card spends 137 points on its spine, gaps, and two 44-point controls. That left 143 points
  for the title at 280 and would leave 90 at 227. Without the `⋯` button a 227-point card gives
  the title 144 points, the same room as the Mac's narrowest card.
- The Mac's minimum is the button's threshold, so no Mac window hides the button. A test walks
  every width from 100 to 4,000 points to hold that.
- iOS 26 full swipe: `max(row, 280) / 2` points. Trailing buttons: `min(84, (row − 44) / count)`
  points each.
- List, accessibility text sizes, and the iPhone layout don't change.

## Where columns appear now

Quadrant width in landscape is `(screen − sidebar − 40) / 2 − 28`.

| iPad, landscape | Sidebar | Quadrant | Columns | Card | `⋯` button |
|---|---|---|---|---|---|
| 13-inch Pro, 1,376 points (measured, iOS 27) | open, 320 | 480 | 2 | 232 | hidden |
| 13-inch Air, 1,366 points (measured, iOS 26.5) | open, 330 | 470 | 2 | 227 | hidden |
| 13-inch Pro | hidden | 640 | 2 | 312 | shown |
| 11-inch Pro, 1,210 points | hidden | 557 | 2 | 270.5 | hidden |
| 11-inch Air, 1,180 points | hidden | 542 | 2 | 263 | hidden |
| 11-inch Pro and Air | open | 382 to 397 | 1 | full width | shown |
| 13-inch Pro and Air, portrait | any | 468 and 464 at most | 1 | full width | shown |

The two measured rows come from simulator runs and the owner's screenshot. The rest are
arithmetic from screen sizes. Where the table says one column, the toggle is dimmed.

## What a narrow card costs

- The title gets 144 to 149 points, about 16 characters a line for two lines.
- A due label with a time can truncate. At 227 points "1 day ago, 12:00 PM" loses its last
  characters. At 232 it fits alone and truncates beside a second badge ("in 2 days, 12…" next to
  the blocked count). The metadata row sits in the title's column, so it stops at the completion
  disc.
- The `⋯` button is gone, and the menu takes a long-press.

## Where the code goes

- `GSDModel/MatrixLayout.swift`: `comfortableCardWidth` (280), `compactCardWidth` (227),
  `minimumCardWidth(onMac:)`, a `minimumCardWidth` parameter on `columnCount`, and
  `cardShowsMenu(forWidth:columns:)`. The model takes the minimum as a parameter, so `swift test`
  on macOS covers the iPad and Mac numbers in one run.
- `GSDModel/SwipeRevealMetrics.swift`: the iOS 26 swipe row's full-swipe distance and trailing
  button width as functions of the row's width. It retires with `SwipeRevealRow`.
- `App/Matrix/QuadrantCell.swift`: picks the platform's minimum in one `MatrixLayout` extension,
  passes the card no menu when `cardShowsMenu` is false, and adds the button trait.
  `TaskCardView` already collapses the button when it gets no menu, so the card doesn't change.
- `App/Matrix/MatrixGridView.swift`: owns the measured quadrant width, which the cells write
  through a binding, and disables the toggle when Columns would draw one column. The four cells
  are equal columns of one grid, so one shared width is correct. The toggle reads the same number
  that lays out the cards.
- `App/Matrix/SwipeRevealRow.swift`: reads both distances from `SwipeRevealMetrics`.
- `ScreenshotTests`: six steps in `SavedFlowTests` and `EscalationFlowTests` tapped the `⋯`
  button, so `openCardMenu()` taps it when it exists and long-presses the card when it doesn't.
  The `RefreshBaseline` walk checks that a matrix card is a button. On a narrow card it drags a
  measured 100 points, because its default swipe completes the task on iOS 26.
  `EscalationFlowTests` finds Mark urgent by how its label starts, because iOS 27 appends the
  menu item's subtitle and the swipe action's icon name.

`xcodegen generate` wasn't needed: no file was added under `App/` and `project.yml` didn't change.

## Verification

- `swift test` passes 1,220 tests in five runs. `MatrixLayoutTests` has 14 tests and the new
  `SwipeRevealMetricsTests` has seven. Each new expectation failed before its code existed.
- The iPad simulator, iPhone simulator, and Mac Catalyst builds succeed on the final code, with no
  warnings in the changed files.
- iPad Pro 13-inch (M5) simulator, iOS 27.0, 1,376 by 1,032 points, landscape, sidebar open. This
  is the owner's configuration. Each quadrant shows two columns of 232-point cards with the
  toggle on. The `RefreshBaseline` walk passes end to end, 12 screens, including the button check
  and a swipe that reveals Complete. Four of five `EscalationFlowTests` pass in one run, including
  Mark urgent from the long-press menu with Undo. The fifth, Mark urgent from a swipe, passes 5
  of 5 alone.
- iPad Air 13-inch (M4) simulator, iOS 26.5, 1,366 by 1,024 points, landscape, sidebar open. At
  228 it drew one column and reported the toggle as `Selected, Disabled`. At 227 it draws two
  columns of 227-point cards. `EscalationFlowTests` passes 5 of 5 and `SavedFlowTests` 3 of 3.
  The walk's button check passes, its measured drag reveals Complete, and the editor opens.
- The walk doesn't finish on iOS 26.5. It stops at the sidebar's Archive row on the Dashboard
  screen, which this change doesn't touch. That step wasn't run against `main`.
- A long-press menu costs a UI test 60 seconds, because XCTest waits for an "animations complete"
  notice that doesn't come while the menu is open. `SavedFlowTests` took 575 seconds on iOS 26.5.

Not verified here, so these are owner checks:

- A real iPad on iPadOS 26 and on iPadOS 27, and the Mac window. The Mac's numbers don't change,
  and its build passes.
- A VoiceOver walk through a quadrant in columns.
- 11-inch iPads. Their rows in the table are arithmetic.

## Found along the way

About half of fresh installs on the iOS 26.5 iPad simulator launch with the matrix cards deaf to
taps for the whole test. The sidebar still works. One test, run once per `xcodebuild` invocation,
failed 4 of 8 times on `main`'s code and 5 of 13 on this branch, so this change didn't cause it.
The iOS 27 simulator showed the same thing in three test launches. The cause isn't diagnosed, and
it hasn't been checked on a real iPad.

## Not in this change

- **13-inch portrait.** Its quadrant is 468 points on the Pro and 464 on the Air, 2 to 6 points
  short of two columns. A 224-point minimum would include portrait and add slack in landscape.
  Portrait holds at one column until the owner decides, and a test pins that.
- **The metadata row.** Letting it run under the completion disc would stop most due labels
  truncating. It changes the card, which the owner asked to keep as it is.
- **App Store screenshots.** The iPad set is captured in landscape with the sidebar open, so the
  next capture shows two columns.
- **What's New copy.** The owner decides at release time.
- **Web parity.** Still open from November 5.
