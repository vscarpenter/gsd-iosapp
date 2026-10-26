# iPhone Duo: the matrix rows in landscape and a large widget

Date: 2026-10-25. Branch: `fix/duo-matrix-rows-and-large-widget`. Review findings 6 and 7 of the
iPhone Duo, iOS 27, and new-device readiness review of 2026-10-24, both low.

## Finding 6: the matrix shows one row on the inner display in landscape

The regular-width matrix is a two-column grid of content-sized quadrant cells, 220 points at
least and growing with their cards, inside one scrolling page. On the Duo's inner display in
landscape the viewport is 669 points tall before the bars, and two rows of cards do not fit, so
the lower half of the matrix sits below the fold. An iPad mini in landscape, 744 points, has the
same problem. iPad Air and Pro, in either orientation, have the height and never showed it.

### Decision

Below 760 points of viewport height the grid pins both rows to half the viewport, less the
grid's inset and gap, and each cell scrolls its own list. Above it nothing changes: cells stay
content-sized and the page scrolls. The threshold is a constant on `MatrixGridView`
(`pinnedRowsBelowHeight`), and `pinnedRowHeight(for:)` turns a viewport height into a row height
or nil. `QuadrantCell` takes `pinnedHeight`; when set, its rows sit in a `ScrollView` and the
cell takes exactly that height. That inner scroll view uses `scrollBounceBehavior(.basedOnSize)`.
Scrollable views bounce by default even when their content fits, and a bouncing cell would take
the pull that the page's refresh needs. With it, a short list stays put and the pull reaches the
page.

The 2x2 staying in view is the matrix's point, so a four-row stack or shorter cards were not
options. Filling the viewport on every iPad was one: it would change the iPad screenshots that
just shipped for no gain on those sizes, so the pin applies only where the rows did not fit.

## Finding 7: no large widget

Today's Focus offered the small and medium families. The Duo's inner Home Screen, like an
iPad's, has room for the large one.

### Decision

The widget now offers `systemLarge` too. Small shows three rows, medium five, and large eight,
which is the whole set the snapshot carries. `WidgetSnapshotBuilder` keeps its limit of eight,
so the app-to-widget contract is unchanged. The large rows use the subheadline size with a
caption marker; small and medium keep caption. The faux Home Screen scene for the video
(`DemoHomeScreen`) renders its own medium entry and is untouched.

## Verification

The iPad mini (A17 Pro, iOS 27.0) in landscape stood in for the Duo's inner display, because a
Device Hub attach left the phone closed. The screenshot walk ran twice into `build/screens/`:
once on main's matrix code (`duo-matrix-before`) and once on the branch (`duo-matrix-after`).
Before, Delegate and Eliminate show one card each at the bottom edge, and the rest of the second
row sits below the fold. After, all four quadrants are in view with their headers and counts, and
each cell shows two cards and scrolls its third inside the cell. Light and dark both captured at
2266x1488.

The iPad Air 13-inch (M4) walk on the branch (`duo-matrix-after-air`, 12 screens per appearance,
zero failures) is unchanged. An ImageMagick pixel diff of its matrix against the day's earlier
`editor-bar` capture reads 0 pixels in dark and 82 of about 5.6 million in light.

`swift test` passed, 283 tests in 31 suites (the package is untouched). `xcodegen generate` left
the project unchanged. The iPhone 18 Pro, iPad Air 13-inch (M4), and Mac Catalyst builds all
succeeded.

Not verified here: the Duo's own inner display, pull-to-refresh on a pinned cell (reasoned from
Apple's `ScrollBounceBehavior` page, which says scrollable views default to `always`), and the
large widget's rendering. See Owner-owed.

A harness note, out of scope here: on the iPad mini the walk misses the sidebar's Archive and
Settings rows in both runs, so those screens are absent from both sets.

## Owner-owed

- Finding 6 on the Duo itself: open the phone in Device Hub, turn it to landscape, and look at
  the matrix. Then pull down on a quadrant with few cards; the matrix should refresh. Attaching
  Device Hub left the phone closed this time, so the inner display was not captured here; the
  iPad mini stood in for the short case.
- Finding 7: add the large Today's Focus widget on the Duo's inner Home Screen, or an iPad, and
  look at it. No simulator path renders a widget family headlessly.
