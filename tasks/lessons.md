# Lessons

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
