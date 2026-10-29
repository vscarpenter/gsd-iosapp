# The matrix: a lone card stretched on iPad and Mac

Date: 2026-10-28. Branch: `chore/release-3.6.3`. Ships in 3.6.3 (39). Supersedes the finding 6
decision in `docs/2026-10-25-iphone-duo-matrix-rows-and-large-widget.md`.

## The bug

On iPad and Mac the matrix is a two-column `LazyVGrid`, and both cells in a row get the taller
cell's height. With one task in Do First and 14 in Schedule, the lone Do First card stretched down
the whole panel. The iPhone list and the web matrix don't hand out spare height, so neither showed
it.

Two things combined. The card's 3-point accent spine was an `HStack` child, and a `Shape` takes
every point of height it's offered, so the card grew to whatever height its container proposed.
The content-sized cell then split its spare height between its trailing `Spacer` and its cards.
The iPad captures from main carry a small version of the same bug: "Book the annual physical" and
"Browse gadget reviews" stretch to match the cards beside them.

## Decision

`TaskCardView` draws the spine as an overlay, so it follows the card's content height and never
sets it. A 15-point leading inset holds the 3-point spine and the 12-point gap it had, and the
cards look as they did. `QuadrantCell` also holds each card row at its natural height with
`.fixedSize(horizontal: false, vertical: true)`, in case a flexible view joins the card later.

`MatrixGridView` now pins both rows to half the viewport on every size, and each cell scrolls its
own list. This replaces the 760-point threshold from October 25 and matches the web matrix, which
bounds its rows with `grid-rows-[minmax(280px,1fr)_minmax(280px,1fr)]` (web #608). The card fix
alone left Do First as an empty panel as tall as Schedule's 14 cards, and it pushed Delegate and
Eliminate below the fold. Keeping the whole 2x2 in view is the matrix's point.

Rows hold at a 220-point floor, the cell's own minimum. Below it the page scrolls. Before, a very
short window could pin a row shorter than 220 points, and the cell's minimum height then painted
it over the row below.

## Tradeoffs

The October 25 decision kept content-sized rows on iPad Air and Pro so the shipped screenshots
wouldn't change. That reason is gone, because this release ships new screenshots.

Equal rows cost something with balanced lists. On the iPad Air 13-inch with the demo seed, Do
First's third card sits partly past its cell's bottom edge and scrolls inside the cell, while the
bottom row has about 180 points to spare. The web makes the same trade.

A pull-to-refresh that starts on a cell whose list overflows scrolls that cell instead of the page.
A short list stays put (`scrollBounceBehavior(.basedOnSize)`), so the pull reaches the page there.
That was already true on the iPhone Duo and the iPad mini in landscape, and it now holds on every
iPad. On the Mac, View > Sync Now (Cmd-R) syncs.

## Verification

The screenshot harness ran on the iPad Air 13-inch (M4), iOS 27.0, in landscape. A copy of HEAD
took a lopsided seed (1 Do First task, 14 Schedule tasks) and ran three ways, into
`build/screens/lop-main`, `lop-cardfix`, and `lop-equalrows`. On main the lone card stretches the
full height of its panel. With the card fix alone the card keeps its natural height, but Do First
is an empty panel and the second row sits below the fold. With the card fix and equal rows, all
four quadrants are in view and Schedule scrolls inside its cell.

The standard demo seed ran on the working tree into `build/screens/review-matrix-fix`, 12 screens
in light and dark with no failures. The stretched cards from main are gone, the spine and text sit
at the same positions, and the swipe reveal fills the full card height.

The equal-rows walk with the lopsided seed failed its editor step. The harness taps "Finish the Q3
board deck" by coordinate, and that seed moves the card off screen inside Schedule's scroll view.
With the standard seed, the same step passes.

`swift test` passed, 288 tests in 33 suites (the package is untouched). `xcodegen generate` left
the project unchanged. The iPhone 17, iPad Pro 13-inch (M5), and Mac Catalyst builds all
succeeded.
