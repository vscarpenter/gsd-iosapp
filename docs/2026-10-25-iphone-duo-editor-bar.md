# iPhone Duo: the editor bar on the outer display

Date: 2026-10-25. Branch: `fix/duo-editor-bar`. Follow-up to the harness work in PR #27, which
reported the finding but did not fix it.

## The bug

On the iPhone Duo's outer display, the task editor is a sheet whose navigation bar holds the
title, Cancel, and Save. Once the form inside it scrolls, all three leave the screen and the
accessibility tree. The bar keeps its 58-point frame and loses every child, and the form sits
unobscured right under the grabber. Scrolling back to the top brings the three back. A plain
iPhone keeps the bar through the same scroll.

## Root cause

iOS 27 can minimize a navigation bar in response to scrolling (`toolbarMinimizationBehavior`).
Its automatic setting is the system's choice per context. On the Duo's outer display the system
draws bars vertically. There, the automatic choice minimizes a sheet's horizontal bar as soon as
its content scrolls down. It restores the bar when the scroll reverses. The editor's bar holds
only text items. Text-only items stay on the horizontal axis on vertical-bar layouts, so the
vertical bar has nothing to show for them, and minimizing the horizontal row leaves nothing on
screen. On a plain iPhone the automatic setting does not minimize, which is why the bug is
Duo-only.

Confirmed by one change: pinning the editor's bar to `.never` turned the failing test green on
the Duo with nothing else touched.

## Decision

`TaskEditorView` pins the editor's navigation bar with
`toolbarMinimizationBehavior(.never, for: .navigationBar)`, guarded for iOS 27 and macOS 27.
The floor is iOS 26, where the modifier does not exist and bars never minimize. The editor is a
modal form. Cancel and Save must stay reachable at every scroll position on every device, so a
stable `never` is the right setting rather than a Duo-only branch.

Considered and left alone: `toolbarVerticalBehavior(.disabled)` on the sheet. It would also
reclaim the empty strip the sheet reserves on its trailing edge for a vertical bar that holds
nothing: the form's rows end 76 points short of the sheet's trailing edge and 16 short of the
leading one. Apple's guidance is to treat that setting as a stable layout choice for UIs better
served by horizontal bars. It changes the sheet's layout, not just this bug, so it is a separate
decision, noted under owner-owed.

## Test

`ReleaseReadinessTests.testEditorBarSurvivesScroll` in `ScreenshotTests/ScreenshotTests.swift`,
gated on `TEST_RUNNER_RELEASE_QA=1` like its siblings. It opens the editor from the capture bar,
expands it with Show all details, scrolls the form once, and expects the title, Cancel, and Save
to still exist. Then it scrolls back and expects Cancel again. Before the fix it failed on the
closed Duo with three failures and passed on iPhone 18 Pro. After the fix it passes on both.

Run it on the closed Duo with:

```
TEST_RUNNER_RELEASE_QA=1 xcodebuild test -project GSD.xcodeproj -scheme GSDScreenshots \
  -destination 'platform=iOS Simulator,id=22BC0A9F-090C-47EB-81EA-290802AA3E22' \
  -only-testing:GSDScreenshotTests/ReleaseReadinessTests/testEditorBarSurvivesScroll
```

## Verification

All on 2026-10-25, on this branch:

- `testEditorBarSurvivesScroll` on the closed Duo: before the fix, three failures (title, Cancel,
  and Save gone after one scroll); after the fix, passed in 25 seconds. On iPhone 18 Pro (iOS
  27.0): passed before and after, 26 seconds each.
- `scripts/capture-screens.sh editor-bar duo`: 14 light and 14 dark screens of the outer display,
  zero test failures, every PNG 1398x2034 with no alpha, in 4 minutes 13 seconds. The editor capture
  shows the bar with Cancel and Save, which the capture in PR #27 lacked.
- `cd GSDKit && swift test`: 283 tests in 31 suites pass (no package source changed).
- `xcodebuild build` for the iPad Air 13-inch (M4) simulator and for Mac Catalyst
  (`CODE_SIGNING_ALLOWED=NO`): both clean. The iPhone simulator build is the test build above.

## Owner-owed

- A hand check on the closed phone: open a task, scroll the form, confirm Cancel and Save stay.
- The vertical-strip decision above: whether the editor sheet should opt out of the vertical bar
  on the outer display and take the width back.
