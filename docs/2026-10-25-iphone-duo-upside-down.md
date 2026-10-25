# iPhone Duo: upside-down portrait on the inner display

Date: 2026-10-25. Branch: `fix/duo-upside-down`. Review finding 5 of the iPhone Duo, iOS 27,
and new-device readiness review of 2026-10-24.

## The finding

`project.yml` listed three orientations for iPhone (portrait and both landscapes) and all four
for iPad. The iPhone Duo is the phone idiom, so both of its displays use the iPhone list. Its
inner display is near-square and iPad-like, and a phone held open gets turned through 180
degrees the way an iPad does. The list refused that turn.

## Decision

The iPhone list now carries all four orientations, matching the iPad list. The change is one
line in `project.yml`, the source of truth, and `xcodegen generate` writes it into
`App/Info.plist`. Nothing in the app reads orientation, every surface already lays out for both
landscapes, and the two lists are now identical.

## What the evidence says

Apple's talk "Prepare your app for iPhone Duo" says two things that bound this change. "The
interface orientation on the outer display behaves like any other iPhone." And "the inner
display doesn't honor your supported interface orientations." If both hold, the list never
decides what the inner display does, and the outer display refuses upside-down the way every
iPhone with Face ID does, whatever the list says. The same talk also says the Duo "respects your
supported interface orientations, but your app will scale on the inner display," and a developer
forum thread reports five different behaviors across list and full-screen combinations, with no
reply from Apple. Nothing I found reconciles the two statements.

A throwaway probe (an XCUITest that turns the device and saves the screen, not committed)
measured what can be measured here. On iPhone 18 Pro the list made no difference: the screen
after an upside-down turn was identical to portrait, pixel for pixel, while the landscape turn
rotated the window to 874x402. That confirms the Face ID refusal in the simulator. On the closed
Duo the probe was inconclusive: the simulator ignores `XCUIDevice.shared.orientation` on the Duo
for every turn, landscape included, with or without the change. Turning the Duo is a Device Hub
action, so the one measurement that settles this is the owner's.

So the change is certain to do one thing and may do another. It enables upside-down portrait on
iPhones with a Home button, where the iPad list already allows it. It may enable the turn on
the Duo's outer display, if that display honors the list and is not Face ID-locked. On the
inner display it changes nothing if Apple's first statement holds, and the app should already
turn there. If the owner's check shows the open phone already follows a 180-degree turn on
`main`, this PR can close without merging and finding 5 is a false positive.

## Verification

All on 2026-10-25, on this branch:

- `xcodegen generate` wrote the four orientations into `App/Info.plist`. Only `project.yml` and
  the plist changed; the pbxproj did not.
- Builds for the iPhone Duo and iPad Air 13-inch (M4) simulators and for Mac Catalyst
  (`CODE_SIGNING_ALLOWED=NO`): clean. The app installed and launched on the Duo, and the bundle's
  plist carries the four.
- `cd GSDKit && swift test`: 283 tests in 31 suites pass.
- The probe above: iPhone 18 Pro refuses upside-down with the list; the Duo simulator ignores
  programmatic turns, so the Duo result is owner-run.

## Owner-owed

- In Device Hub, turn the open Duo through 180 degrees with today's `main` build. If the app
  already follows, close this PR as not needed. If it does not, install this branch's build and
  turn again, closed and open.
