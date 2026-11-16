# The matrix: a header band for each quadrant

Date: 2026-11-16. Branch: `feat/matrix-header-band`, PR #108.

## Why

The owner ran a color pass on the app. The audit found the palette sound and its placement off.

- The quadrant's color went to thin marks: a 3-point card spine, a 20-point heading, and small
  tag chips. All four panes were otherwise white, so the grid did not read by region.
- The web's design contract (`gsd-taskmanager/DESIGN.md`) gives each pane a header band and keeps
  tags neutral. iOS had neither.
- Tag chips took their task's quadrant color. A Delegate tag measured 4.17:1 at footnote size,
  under the 4.5:1 floor.
- Two buttons were drawn in gray: "Pick up to three for today" and the empty quadrant's
  "Add to Do First".
- "Due today" was drawn in tide. Tide is also the action color and Schedule's color, so in a
  Do First card it read as a link.

## What ships

The owner chose these on 2026-11-16 from three options rendered in the simulator.

- **Header band.** On iPad and Mac, a quadrant's heading sits on a band in the quadrant's tint
  (`QuadrantStyle.wash`) across the top of its pane. On iPhone, the heading moves from a section
  header on paper into the card, as its first row on the same band. The count beside the heading
  is `ink2`.
- **Neutral tags.** A tag chip is `ink2` on `sunken` wherever the app draws one: cards, the
  editor, and the onboarding sample. The capture bar already drew this chip. This reverses the
  tinted chip from 2.0.0.
- **Tide on two prompts.** "Pick up to three for today" and the empty quadrant's "Add to ..."
  phrase take `Surface.tint`.
- **"Due today" in ink.** Semibold weight sets it apart from an upcoming date. Overdue stays rust
  with its warning icon.

The card spine, the completion disc, and the subtask bar keep the quadrant's pigment. No token
changed value and no color was added. The total amount of color is about the same. It moved from
many small chips to four headers.

## What was ruled out

- **A full-pane wash.** The web tints the whole pane with a quieter wash. Card metadata uses
  `ink3`, which measures about 4.0:1 on any of the four washes. In list layout the rows sit
  directly on the pane, so that text would fail AA.
- **The count in `ink3`.** It measures 3.8 to 3.9:1 on a band.
- **A pigment rule on the pane's top edge.** The web has one. On a 22-point rounded pane it reads
  as a colored border, and the band already states the quadrant.

## Contrast

| Pairing | Light | Dark | Floor |
| --- | --- | --- | --- |
| Do First heading on its band | 4.81 | 4.70 | 3.0, large text |
| Schedule heading on its band | 5.26 | 5.46 | 3.0, large text |
| Delegate heading on its band | 4.17 | 6.84 | 3.0, large text |
| Eliminate heading on its band | 4.54 | 5.84 | 3.0, large text |
| Count (`ink2`) on a band | 4.51 to 4.63 | 5.28 to 5.74 | 4.5 |
| Tag chip (`ink2` on `sunken`) | 4.51 | 7.36 | 4.5 |
| Tide prompt on paper | 5.61 | 7.20 | 4.5 |
| Tide prompt on a card | 6.33 | 6.55 | 4.5 |
| "Due today" (`ink` on a card) | 16.60 | 14.09 | 4.5 |
| Prompt headline (`ink3` on a card) | 4.70 | 4.87 | 4.5 |

One pairing got worse. The Delegate heading was 5.0:1 on white and is 4.17:1 on its band. It
passes AA as large text at the default size, where the heading is 20 points. It no longer clears
AAA-large. At the smallest text size the heading is 17 points, where AA asks for 4.5:1.

The web solves this pairing with a darker ochre for text, `#74591C`, which measures 5.44:1 on the
band. The owner declined darker ochre headings for iOS in August 2026, when the heading sat on
white and passed. The band changes that math, so the question is open again.

## Differences from the web

- The web draws "Due today" as a tide chip. iOS now uses ink.
- The web tints the whole pane and adds a 3-pixel pigment rule. iOS has the band only.
- The web uses darker inks for ochre and slate text. iOS uses the pigment.

## Verification

Rendered on the iPad Air 13-inch and iPhone 17 Pro simulators on iOS 26.5, in light and dark.

- iPad in landscape with two columns, and in portrait with one.
- iPhone matrix, a smart view list, and the editor.
- The empty quadrant's prompt on both, from a throwaway build that forced Do First empty.
- The capture walk passes all 14 screens on iPhone in both themes. On iPad it stops at the
  sidebar's Archive row on the Dashboard screen. The same run on unchanged code stops there too.

`swift test` passes 1,220 tests. The iOS simulator build and the Mac Catalyst build succeed.

UI tests on iOS 26.5:

- **iPad Air 13-inch.** `EscalationFlowTests` passes 5 of 5 and `SavedFlowTests` 3 of 3.
  `EditorSaveShortcutTests` passes 7 of 7, with one test that runs on Mac Catalyst only. One Saved
  test failed in the class run and passed twice alone. That matches the launch flake recorded
  for this simulator on 2026-11-15.
- **iPhone 17 Pro.** `SavedFlowTests` passes 3 of 3. `EscalationFlowTests` fails 5 of 5 and two
  editor tests fail, and the unchanged code fails the same seven. This simulator was created on
  2026-11-16, so these were its first runs, and the cause is not diagnosed.
- **One flaky test on iPhone.** `testDoesNothingBehindTheDependencyPicker` failed 2 of 4 runs
  with the change and passed its one run without it. It runs on an empty store, where none of
  the changed views draw, and its log shows the tap landing right after a scroll.

Not rendered: the onboarding sample chip, the iPhone matrix in Edit mode, and Mac Catalyst, which
was built only. The iOS 27.0 simulator runtime was unavailable on this Mac on 2026-11-16, so
nothing ran on iOS 27.

## Not in this change

- No What's New entry. The change has no version yet.
- The App Store screenshots show the old matrix.
- The editor's quadrant picker draws a selected Delegate label in ochre on its tint at footnote
  size, 4.17:1. That predates this change.
- The sidebar's smart view icon colors.
