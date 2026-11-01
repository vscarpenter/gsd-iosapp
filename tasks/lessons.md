# Lessons

## Keyboard tests on the simulator have two traps (2026-11-01)

The simulators usually drop the first ⌘ key after a launch, whichever shortcut it is, and the second press works. A swipe that starts over the iPad's software keyboard types instead of scrolling: a form swipe turned a title into `File the receipts77777777`.

**Rule:** retry a shortcut that's only the way into a test, and press the shortcut under test once. Priming with another ⌘ key hides a dropped first press, so test that flow where the keyboard is real. Start scroll drags above the keyboard.

## A sheet's key commands fire from behind what it presents (2026-11-01)

A `.keyboardShortcut` on a sheet's Save button fired behind the sheet's own alert and behind a nested sheet, and saved a draft the user was being asked to discard. Nothing dims or blocks it the way a modal blocks a tap.

**Rule:** disable the button whenever the sheet presents something over itself, and test the shortcut with each presentation up.

## Opening the project in Xcode 27.1 rewrites generated files (2026-10-28)

A working tree for a two-file matrix fix also held changes to `project.pbxproj` and both shared
schemes. Xcode 27.1 had re-saved them (`LastUpgradeCheck = 2710`, scheme version 1.3, dropped
default attributes) and written 3.6.2 (39) into the app target only. The build then warned that
the extensions' 3.6.1 didn't match the app's 3.6.2. `project.yml` still said 3.6.1 (38), so the
next `xcodegen generate` would have reverted all of it anyway.

**Rule:** never commit pbxproj or scheme changes that `project.yml` didn't cause. Discard them
with `git checkout -- GSD.xcodeproj`, and bump versions only through `scripts/bump-version.sh`.

## A capture is only as fresh as the test bundle behind it (2026-10-25)

The first Duo diagnostic run showed the branded title back on the outer display and looked like
a regression of PR #26. It was not: `xcodebuild test-without-building` ran the `GSD.app` that
`build-for-testing` had produced at 16:09, 85 minutes before the fix landed. The screenshots were
true, of the wrong build.

**Rule:** before reading anything into a `test-without-building` capture, compare the mtime of
`build/dd/Build/Products/*/GSD.app/GSD` with the commit under test, or run `build-for-testing`
again. It costs seconds when nothing changed.

## The Duo's display UUIDs change on every boot (2026-10-25)

The port UUIDs that `simctl io screenshot --display=` takes were saved from one boot and failed
on the next with "does not have a display port." `simctl io enumerate` lists the live ports with
their default width, and the two Duo framebuffers are the only ones at 1398 and 2007 pixels wide.

**Rule:** never hard-code a Duo display UUID. Look it up by width at run time, and wrap the
screenshot in `timeout`: a screenshot of a dark display can hang.

## The in-test screenshot is the App Store Connect capture (2026-10-25)

`XCUIScreen.main.screenshot()` on the Duo writes the live display at its native pixel size with
no alpha channel, which is exactly what App Store Connect accepts. The host-side
`simctl io screenshot` of the same display carries an alpha channel, `sips -s hasAlpha no` leaves
it in place, and stripping it means another tool in the path.

**Rule:** for a screenshot that may be uploaded, capture inside the walk and pixel-verify the
file (`sips -g pixelWidth -g pixelHeight -g hasAlpha`) instead of post-processing a host capture.

## A sheet's bar can minimize to nothing on the iPhone Duo (2026-10-25)

iOS 27 minimizes a navigation bar on scroll when its automatic behavior says so, and on the
Duo's outer display that includes a sheet's horizontal bar. The task editor's bar holds only
text items, which have no vertical form, so one scroll left the sheet with no title, Cancel,
or Save until the scroll reversed. A plain iPhone never minimized it, so no iPhone capture
would have shown the bug.

**Rule:** a modal form pins its bar with `toolbarMinimizationBehavior(.never, for:
.navigationBar)`. And when a bar keeps its frame but loses its children in a hierarchy dump,
suspect minimization before suspecting the toolbar items.

## The Duo simulator ignores programmatic turns (2026-10-25)

`XCUIDevice.shared.orientation` turns an iPhone 18 Pro simulator (the window went to 874x402 on
a landscape turn) and does nothing on the iPhone Duo, closed or open, for any orientation.
Turning the Duo is a Device Hub action, so every orientation question on it is owner-run. The
same probe showed the iPhone 18 Pro refusing upside-down portrait with that orientation listed,
which is the Face ID rule, in the simulator too.

**Rule:** to learn whether a turn was honored, save `XCUIScreen.main.screenshot()` before and
after and compare the pixels. Identical means refused. The window frame alone misses the
upside-down case, where the size does not change.

## A vertical-bar fix is measured against the title row, not the bar (2026-10-24)

The Duo review assumed the text-only Edit button forced a second, horizontal bar on the
vertical-bar layout. Captures of the fixed build showed the system keeps a horizontal title row
for every inline navigation title, items or not. Edit cost nothing there, and
`axisBehavior(.horizontalOnly)` moved nothing. Only the custom principal title was worth hiding.

**Rule:** before changing toolbar items for iPhone Duo, capture the screen with the item removed
and see what the system still draws. Fix what the capture shows, not what the HIG text implies.

## iOS 27.1 environment values may not exist in the Catalyst SDK (2026-10-24)

`@Environment(\.toolbarVerticalEdge)` built for every iOS simulator and failed the Mac Catalyst
build with "generic parameter 'Value' could not be inferred". The macOS and iOSSupport
interfaces do not declare it. The iOS SDK's `anyAppleOS 27.1` availability says nothing about
Catalyst.

**Rule:** a new environment key path needs `#if targetEnvironment(macCatalyst)` around the read,
and the three-destination build before the commit, every time.

## A brief's toolchain claims are hypotheses until the SDK agrees (2026-09-15)

The iOS 27 refresh brief asked for `SWIFT_VERSION: "6.4"`. That setting is the language mode,
and the 6.4 compiler accepts only 4, 4.2, 5, and 6 there. The brief also described toolbar
"auto-minimizing" as one API when the SDK splits it in two (`visibilityPriority` orders the
overflow menu; `tabBarMinimizeBehavior` hides the tab bar on scroll), and it expected
`SwipeRevealRow` to retire while the floor stayed at iOS 26, where the replacement does not
exist.

**Rule:** before planning around an API, grep the SDK's `.swiftinterface` for the symbol and
its `@available` line, and read the `.swiftdoc` strings for what it does. Ten minutes of
grepping settled every one of these before any code moved.

## Layered icons list groups front to back (2026-09-15)

An Icon Composer `icon.json` with the check layer listed after the tiles compiled cleanly and
rendered no check at all. Groups are ordered front to back, so the topmost layer comes first.
actool validates the JSON, not the composition, so a wrong order is invisible until a preview.

**Rule:** flatten the package with `actool --platform macosx` and look at the `.icns` before
wiring the icon into the project.

## Screenshot walks break on the features they verify (2026-09-15)

`tabBarMinimizeBehavior(.onScrollDown)` removes the inactive tab buttons from the
accessibility tree while the bar is minimized, and a slow scroll up in the harness does not
always expand it. Every tab tap after a scroll failed while the screenshots kept being
written, so the files showed the wrong screens with plausible names.

**Rule:** a UI-test helper that navigates must assert the element exists before tapping and
fail loudly when it does not, or the capture set lies. Tapping the minimized bar expands it.

## Simulator and Catalyst UI tests have environment rules (2026-09-15)

- Two `xcodebuild test` sessions on one simulator kill each other. A device is free only after
  its last pass, not after its first.
- The Catalyst test runner is sandboxed: it cannot write outside its container, so captures
  go to the runner's temporary directory and the script copies them out.
- Catalyst UI tests need an unlocked GUI session. A locked screen leaves the app "Running
  Background" and every capture is empty, with no crash and no clear error.
- The iOS 27 simulator's Settings app has no Display & Brightness page, so the Liquid Glass
  slider is a device-only check.

## The system's selection fill is not yours to predict (2026-09-15)

The 27 SDK changed the sidebar selection fill in both directions: opaque app tint on iPad and
a neutral fill on macOS while the sidebar is unfocused. A per-platform guess about the fill's
color (paper text on Catalyst only) was wrong on both after the SDK moved. `.primary` on the
selected row follows whichever fill the system paints.

## The simulator recorder only writes a frame when the screen changes (2026-09-07)

`simctl io recordVideo` produced a 7-second clip of a static screen with two video
packets. Everything downstream that reasons in packets misreads it: an ffmpeg `-t` placed
before `-i` measured the duration against those packets and every clip came out about a
second long, and the container duration is only as accurate as the last change.

**Rule:** treat raw simulator captures as sparse. Convert them to constant 30 fps first
(`-vf fps=30`), trim with `-t` as an output option, and verify with ffprobe rather than
trusting the recorder's numbers. Also keep the app on screen for a second after the last
beat, or the springboard lands in the tail of the clip.

## XCUITest scrolls elements "into view" in portrait coordinates (2026-09-07)

Tapping the iPad keyboard's Hide key with `tap()` failed in landscape with
"Failed to scroll to visible" because the key's frame was reported in portrait space and
looked off-screen. `element.coordinate(withNormalizedOffset:).tap()` skips that scroll and
taps where the key actually is. The same portrait framebuffer is what `recordVideo`
captures, so landscape iPad clips need a 90-degree rotation in post.

## Two clients that agree with themselves can still disagree with each other (2026-08-28)

Every same-client round-trip test passed while cross-client backups were broken in
both directions. Each implementation was internally consistent; they simply encoded
the same contract differently. Unit tests written against your own output cannot
see that — they are a mirror, not a check.

Three real mismatches all surfaced within minutes of restoring a *real* export from
the other client, and none had surfaced before:

- `version` as `Int` here vs `string` there (import refused outright).
- `FilterCriteria` demanding all thirteen keys while the web writes only the ones a
  view constrains on (no real web smart view could decode).
- `Task` omitting the derived `quadrant`, which the web requires as a column.

**Rule:** when two codebases share a wire format, commit a matched pair of real
artifacts — one produced by each — and have both suites read both. A hand-written
fixture would have encoded the same misunderstanding as the code it tests.

## A test can pass vacuously when the code moves underneath it (2026-08-28)

`deleteAbortsAndKeepsRowWhenEnqueueFails` asserted `!log.events.contains("delete")`.
Making delete a soft delete meant `TaskRepository.delete` was never called at all,
so the assertion became trivially true and the test kept passing while checking
nothing. Its sibling failed loudly and pointed at it.

**Rule:** when a write moves to a different collaborator, check the *negative*
assertions in nearby tests. A green test whose subject no longer exists is worse
than a red one.

## The build cache remembers where the repo used to live (2026-08-28)

Moving the repo into a parent folder left `.build` full of absolute module-cache
paths, and every compile failed with "missing required module 'SwiftShims'". Not a
code problem. `swift package clean` fixes it — and is the right tool rather than
`rm -rf .build`.

## A dev-signed Catalyst build is the installed app (2026-10-25)

The screenshot harness launched the Mac dev build with `--demo-seed`, and the seed deleted every
task in the store, queuing a server delete for each. The build was signed with the owner's team
and app group, so it opened the installed app's database in
`~/Library/Group Containers/group.dev.vinny.gsd` and read the installed app's session from the
shared keychain. The seed trashed 166 real tasks and the launch sync pushed the deletes.
Simulators had hidden this for months, because they are never signed in.

**Rule:** anything that erases or replaces a store must run against a store it owns. A harness
launch gets its own in-memory database, no session, its own defaults suite, and scratch files
for every shared seam, decided once in `GSDApp.init` by one switch that any harness argument
flips, and the seed refuses any non-empty store. The database is one seam of six.
"Unreachable in normal launches" is not a safety property when the abnormal launch runs on the
owner's Mac.

## Saved needs a placement boundary across every active surface (2026-10-26)

Keep the full stored task set for backup, sync, account checks and dependency graphs;
filter Saved at active presentation/scheduling boundaries. A Saved prerequisite is
still unfinished. Clearing a PocketBase text field requires an explicit empty string.
An incoming return also resets this device's reminder state, even though ordinary
remote edits preserve device-local reminder fields. Exercise the real server's
merging PATCH behavior as well as mapper round trips.

SwiftUI row identifiers on an implicit group can replace child-control identifiers.
Use an explicit accessibility container when a row has independent actions. On iOS
27, native search hides the tab bar behind its keyboard; bind search presentation
and close it when opening a Saved editor. Tests must target Saved search separately
from the global palette and read notes from the editor, since matrix cards use a
custom VoiceOver label that does not include the description.

Compare Undo against the committed row: SQLite normalizes fractional timestamps,
so an in-memory save snapshot with sub-millisecond precision can falsely fail an
unchanged-state check. Include a fractional-clock test as well as whole-second clocks.
For iPad screenshots use `XCUIScreen.main`, as in the existing baseline harness;
`app.screenshot()` can crop the rotated window. Selected iPad sidebar labels need
paper ink against the app's ink selection fill in both appearances.

## A new synced field needs a one-time backfill (2026-10-27)

Adding a wire column is not enough. A build that pulled the record before the column
existed stored the row at the same `client_updated_at` the server still holds, and the
pull cursor sits past it. Neither an incremental pull nor a cursor reset brings the
field across, because an equal stamp is a no-op on both clients. Stamp the cursor with
a contract version, and when it predates the build, pull everything once and merge
same-version rows. Never clear the cursor to force that pull: a nil cursor triggers the
first-sign-in seed, which pushes every local row with the field still empty.

## Tasks leaving the server read as deletes to anything still syncing (2026-10-31)

An erase that runs under a live session looks like remote deletes to realtime and to reconcile, and either one removes the local row. Hold sync for the whole operation, and end the session if it fails after removing anything. Stopping sync in memory isn't enough, because a relaunch restarts it.

