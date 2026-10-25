# iPhone Duo: screenshot harness

Date: 2026-10-25. Branch: `fix/duo-screenshot-harness`. Follows PR #26.
Source: finding 3 of the 2026-10-24 iPhone Duo, iOS 27, and new-device readiness review. The
harness (`scripts/capture-screens.sh` driving `ScreenshotTests/RefreshBaseline.swift`) could not
drive or capture the iPhone Duo, and App Store Connect will want Duo screenshots from April 2027
for apps built with the iOS 27.1 SDK.

## What the Duo looks like to the harness

Facts measured on the iPhone Duo simulator (iOS 27.1, Xcode 27.1) before any change:

- The simulator boots closed. The outer display is live at 1398x2034 pixels (466x678 points,
  compact width) and the inner display is dark. Device Hub is the only way to open the phone,
  and a pose set there survives detaching Device Hub. No `simctl` subcommand or XCTest API
  changes the pose.
- `XCUIScreen.main.screenshot()` inside the walk captures the live display at its native pixel
  size with no alpha channel. Those are the App Store Connect sizes for the Duo (1398x2034
  outer, 2007x2853 inner) and the format it accepts. A host-side `simctl io screenshot` of the
  same display carries an alpha channel that `sips` cannot remove, so the in-test path is the
  one to keep.
- The two framebuffers have port UUIDs that change on every boot. `simctl io enumerate` lists
  them with their default width, which is how the script finds them.
- A dark framebuffer is not black to ImageMagick: the screenshot is a 1-bit image with an alpha
  channel and its gray mean reads a flat 0.5, the same as some lit screens. Its standard
  deviation is 0, while a display that is drawing anything reads 0.06 or more, so variation is
  the test for "live", not brightness.
- On the outer display the tabs are a vertical column of plain `Button` elements labeled
  Matrix, Browse, Dashboard, and Settings. There is no `tabBars` element, so the old
  `selectTab` never found a tab.
- An unfolded Duo reports the phone idiom while showing the regular root, so a walk that picks
  compact or regular by idiom picks wrong on the inner display.
- The system back button moves into the vertical strip too. It keeps its `BackButton`
  identifier there, while the first button left in the navigation bar is Edit, so a walk that
  pops by tapping the bar's first button enters edit mode instead.
- The test runner's app bundle is whatever the last `build-for-testing` produced. The first
  diagnostic run here used a bundle built 85 minutes before PR #26 landed and showed the branded
  title back on the outer display; the fresh bundle shows the plain title.
- A run of the unchanged walk on the closed Duo failed 13 of its steps: no tab bar, every tab
  switch, and everything behind an editor sheet that never closed.

## Decisions

- **Two platforms, each runnable alone.** `duo` is headless: the script shuts the simulator down
  and boots it again, which is the one scripted way to the closed pose, checks that the outer
  display is drawing, and runs the walk light and dark. `duo-open` boots the simulator, prints
  an instruction to open the phone in Device Hub in portrait, and polls the inner framebuffer
  (every 5 seconds, `DUO_WAIT` seconds in all, default 600) until it shows variation. The owner chose
  this over an outer-only pass and over one combined run that would have to pause for a hand.
- **The walk asks the screen which root it is showing.** Both roots show the capture field, so
  the walk waits for it and then looks for the Browse tab, which only the compact root has.
  The iPad branch still rotates to landscape first.
- **`selectTab` falls back to the labeled button** when no `tabBars` element exists, and
  expands a minimized bar by tapping whichever tab button is still present.
- **`goBack` matches the `BackButton` identifier first** and falls back to the navigation bar's
  first button only for the Mac, where the identifier was not checked.
- **The editor drag runs only when the sheet is not already expanded.** The sheet grabber
  reports `Expanded` at the large detent. On the outer display the sheet can open there
  already, and the drag that lifts a medium sheet scrolls a large one instead.
- **Every Duo PNG is pixel-verified** for the exact size and for no alpha channel before the
  run reports success, so the files can go to App Store Connect as they are.
- **Portrait only on the inner display.** The framebuffer capture does not rotate with the
  device and `XCUIDevice.shared.orientation` does not turn the inner display, so a landscape
  pose would need a rotation step whose direction depends on how the owner turned the phone.
  The walk prints the window size in points so a landscape run is visible in the log.
- **Composites stay out.** The raw captures are the App Store Connect set. Framing, headlines,
  and the choice of which frames to upload stay with the launch kit, and the "optimized for
  iPhone Duo" badge that an upload earns is a product claim for the owner to make.

## New finding: scrolling the editor empties its bar on the outer display

Reproduced on the fresh build, three times out of four runs. The task editor is a sheet with a
navigation bar that holds the title, Cancel, and Save. On the Duo's outer display, once the form
inside it scrolls, all three leave both the pixels and the accessibility tree: the `NavigationBar`
with identifier `Edit Task` keeps its frame and loses its children, and the sheet's `Toolbar`
is empty. They were still gone with the form scrolled to its end. A plain iPhone keeps the bar
through the same scroll.

The harness met it through its own drag. The old drag started 40 points below the grabber, and
on the shorter outer display that point lands on the form, so one gesture lifted the sheet to
large and scrolled the form in the same stroke. The run where the stroke happened to stop at the
top kept the bar; the runs where it scrolled lost it. The walk now drags the grabber element
itself and, if Cancel is still missing, drags the sheet away so the rest of the walk continues.

Owner-owed, by the design decision for this PR: confirm it by hand on the closed phone (open a
task, scroll the form, look for Cancel and Save, scroll back up), then fix it in a follow-up.
The hierarchy dumps are in the session's `green2` result bundle attachments.

## Verification

All on the fresh build of this branch, 2026-10-25:

- `scripts/capture-screens.sh duo-harness duo`: reboot into the closed pose, 14 light and 14
  dark screens of the outer display, zero test failures, every PNG 1398x2034 with no alpha, in
  4 minutes 8 seconds. The walk log shows the window at 466x678 points and the sheet grabber at
  "Half screen" before the drag.
- The same walk on iPhone 18 Pro (iOS 27.0): 14 and 14 screens, zero failures, 1206x2622, as
  in the baseline set.
- The same walk on iPad Air 13-inch (M4) (iOS 27.0): 12 and 12 screens, zero failures,
  2732x2048. The script's old iPad default named a simulator that no longer exists, and the
  13-inch iPad Pro that does exist runs iOS 26.5, where the sidebar's Archive icon is the first
  element with that label and is not tappable. The default now names the 27.0 Air.
- `cd GSDKit && swift test` is untouched by this change (no package source changed).
- `scripts/capture-screens.sh duo-harness duo-open`: run with `DUO_WAIT=3600`. It printed its
  instruction, polled the dark inner display for the full hour, then stopped with "the inner
  display never came on" and exit code 1, which is the timeout path working as designed. Nobody
  opened the phone during the run, so the inner walk has not run yet. Its result is recorded here
  the first time the owner opens the phone in Device Hub and re-runs `duo-open`.
- `xcodebuild build-for-testing` of the GSDScreenshots scheme for Mac Catalyst: compiles. The
  only warnings are pre-existing ones in `ScreenshotTests/ScreenshotTests.swift`.

## Owner-owed

- `duo-open` whenever an inner-display set is wanted: open the phone in Device Hub, portrait.
- The App Store Connect upload itself, and the badge decision that comes with it.
