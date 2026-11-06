# The matrix: adaptive columns on iPad and Mac

Date: 2026-11-05. Branch: `feat/matrix-adaptive-columns`. Mockup:
https://claude.ai/artifact/7f79Qky2qJAeKmXFAmeKPc (private to the owner).

## Why

A feedback submission asked to "size tasks in the matrix at 1/3 width and 1/2 height." On iPad and
Mac each quadrant is a one-column list, so a short title like "Call the bank" sits alone in a row
450 or more points wide. Fixed tiles would fix the wasted width but bring new problems: the card's
two 44-point controls take most of a third-width tile, 80-character titles clip, and fixed heights
undo the October 28 card-stretch fix. The owner chose adaptive columns first, then a check on
whether anyone still asks for fixed tiles.

## What ships

Each quadrant lays out its cards in as many columns as fit, with every card at least 280 points
wide. A List / Columns switch in the iPad and Mac matrix toolbar flips between this layout and
today's one-column list.

- **Default is Columns** (owner decision). Existing users see columns on wide windows after the
  update, and List is one tap away.
- **The switch lives in the toolbar only** (owner decision), next to Show Completed, styled the
  same way. No Settings row, ⌘K command, or View menu item in this change.
- **Per device, never synced.** The choice is stored under `AppGroupDefaults.Key.matrixLayout`.

## Rules

- Columns: `max(1, floor((width + 16) / (280 + 16)))`, where width is the quadrant's content
  width. Two columns need 576 points and three need 872.
- List is always one column.
- Accessibility text sizes always get one column, because cards grow tall and narrow columns would
  clip them.
- A hairline sits above every card below the first row, so each column reads as its own list. In
  one column this matches today's rhythm exactly: card, 10 points, hairline, 10 points, card.
- Cards in a row align to the top. A lone card keeps its column width instead of stretching.
- The card itself doesn't change, and neither do swipe actions, drag between quadrants, the menus,
  or tap to edit.
- iPhone and compact-width iPad keep the stacked list in `MatrixView`. They show no switch.

## Where columns appear

At 280 points with the matrix's 12, 16, and 14 point insets, the detail area needs 1,248 points
for two columns and 1,840 for three. A 13-inch iPad in landscape with the sidebar showing gives
each quadrant about 480 points, so it stays at one column. Columns appear on iPad in landscape
with the sidebar hidden, in large Stage Manager windows, and on the Mac. The Mac draws the iPad
layout at 77 percent scale (device family 1,2), so a 1,280-point Mac window is about 1,660 app
points wide and gets two columns.

The switch stays enabled when only one column fits, where Columns looks the same as List. Hiding or
disabling it on every resize would be more confusing, and its accessibility hint says it uses
columns when there's room.

## Where the code goes

- `GSDModel/MatrixLayout.swift`: the `list` and `columns` cases, the default, and the pure
  column-count rule, beside `EscalationWindow`. Unit tested, because the App target has no test
  target.
- `GSDStore/AppGroupDefaults.swift`: the `matrixLayout` key.
- `App/Matrix/QuadrantCell.swift`: measures its content width and lays the cards out in a
  `LazyVGrid` with that many flexible columns. List uses the same path at one column, so there's
  one layout to maintain.
- `App/Matrix/MatrixGridView.swift`: reads the setting with `@AppStorage`, adds the toolbar toggle,
  and passes the layout to each cell.

## Not in this change

- **Web parity.** The web matrix would take the same rule as
  `repeat(auto-fill, minmax(280px, 1fr))`. Until it ships, this is a one-sided iOS layout option.
  It needs a web change or a line in each repo's `PRODUCT.md` before the next parity audit.
- **The loading skeleton** keeps its one-column shape. It shows only until the first fetch lands.
- **What's New copy and App Store screenshots.** The owner decides at release time. Portrait iPad
  captures look the same, because they stay at one column.
