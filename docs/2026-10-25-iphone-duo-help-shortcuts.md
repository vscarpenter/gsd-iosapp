# iPhone Duo: keyboard shortcuts in the Field Guide

Date: 2026-10-25. Branch: `fix/duo-help-shortcuts`. Review finding 4 of the iPhone Duo, iOS 27,
and new-device readiness review of 2026-10-24: the app's one layout-affecting idiom check.

## The finding

The Field Guide (Settings, "How to use GSD") lists keyboard shortcuts only where a hardware
keyboard is realistic. It decided that from the device idiom: the Mac always, the pad idiom yes,
the phone idiom no. An open iPhone Duo reports the phone idiom while showing the regular-width
root, so its inner display hid the section. Apple's Duo guidance says not to decide layout from
the idiom, and every other branch in the app already keys off `horizontalSizeClass` or the
Catalyst target.

## Decision

The sheet takes its presenter's width, as the task editor already does. `ContentView` presents
`HelpView(compactPresenter: sizeClass == .compact)`, and the section shows when the presenter is
regular, with the Mac always showing it. A sheet cannot read the size class itself, because a
sheet's own environment reads compact even on a full-width iPad.

What changes where: iPhone and the closed Duo stay hidden. A full-width iPad stays shown. The
open Duo is now shown, which is the fix. An iPad window narrow enough to be compact is now
hidden where it was shown before. That last case follows the app's rule for the editor and the
roots, and the shortcuts themselves still work there.

Considered and left alone: also showing the section when a hardware keyboard is connected
(`GCKeyboard.coalesced`), which would cover an iPhone with a keyboard. One rule covers the
finding. A capability check is a separate decision.

## Test

`ReleaseReadinessTests.testHelpShortcutsFollowTheRootWidth` in
`ScreenshotTests/ScreenshotTests.swift`, gated on `TEST_RUNNER_RELEASE_QA=1`. It opens Settings
from whichever root is showing, taps "How to use GSD," and expects the KEYBOARD SHORTCUTS
section exactly when the root is regular. On iPhone and iPad the old rule and the new one agree,
so the test is green before and after there. It was not seen red: the one device where it fails
without the fix is the open Duo, which only the owner can pose. Run it there with:

```
TEST_RUNNER_RELEASE_QA=1 xcodebuild test -project GSD.xcodeproj -scheme GSDScreenshots \
  -destination 'platform=iOS Simulator,id=22BC0A9F-090C-47EB-81EA-290802AA3E22' \
  -only-testing:GSDScreenshotTests/ReleaseReadinessTests/testHelpShortcutsFollowTheRootWidth
```

## Verification

All on 2026-10-25, on this branch:

- `testHelpShortcutsFollowTheRootWidth` on iPhone 18 Pro (iOS 27.0): passed in 22 seconds, the
  compact root with no shortcuts section. On iPad Air 13-inch (M4) (iOS 27.0): passed in
  21 seconds, the regular root with the section. The open Duo is owner-run (above).
- `cd GSDKit && swift test`: 283 tests in 31 suites pass (no package source changed).
- Builds: the iOS simulator test build, and Mac Catalyst with `CODE_SIGNING_ALLOWED=NO`, both
  clean. `HelpView` dropped its UIKit import, which served only the idiom line.

## Owner-owed

- Run the test above, or open the Field Guide by hand, on the open Duo in Device Hub.
