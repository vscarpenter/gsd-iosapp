# GSD product video: design (Phase 1)

Status: awaiting owner approval before any recording or scaffolding.
Branch: `video/product-demo`. Nothing is committed yet.

## Deliverables

| File | Size | Layout |
| --- | --- | --- |
| `out/gsd-16x9.mp4` | 1920x1080 | iPhone and iPad side by side |
| `out/gsd-9x16.mp4` | 1080x1920 | one centered iPhone |
| `out/gsd-1x1.mp4` | 1080x1080 | one centered iPhone |

All three run 45 seconds at 30 fps, H.264 video, AAC audio, never letterboxed.

## What the app actually does (verified in code and spec)

Main user flows, from `spec.md` and the `App/` feature folders:

1. **Matrix.** iPhone stacks the four quadrant sections with live counts; iPad shows a true 2x2 board in a split view with drag and drop across quadrants.
2. **Quick capture.** One field with live shorthand parsing: `!!` sets Do First, `!` urgent, `*` important, `#tag` adds a tag, URLs move to the description. The quadrant chip recolors as you type.
3. **Complete.** Leading swipe or disc tap. Success haptic and confetti (suppressed under Reduce Motion). Recurring tasks spawn the next instance.
4. **Task editor.** Quadrant picker, due date presets, tags, recurrence, subtasks, dependencies with live cycle checks, reminders, estimate, time tracking.
5. **Browse and smart views.** Nine built-in views (Today's Focus, This Week, Overdue Backlog, and so on), custom views, pinning, root search.
6. **Command palette.** Cmd-K on iPad and Mac; search affordance on iPhone.
7. **Dashboard.** Active, Completed, Completion, Tracked stat cards; Completion Trend (7, 30, 90 days); Active by Quadrant donut; Completion by Quadrant rings; Top Tags; Upcoming Deadlines.
8. **Native surfaces.** Today's Focus widget, App Intents and Siri, Share Extension, Spotlight, Home Screen quick actions.
9. **Sync and account.** Optional sign in (Google, Apple, GitHub) to sync with the web app. Fully usable offline with no account.
10. **Backups.** JSON export and import, 30-day trash, archive.

Landing page claims, quoted for reuse: "Get the right things done." · "Free · Private · No sign-up" · "Web, iPhone, iPad, and Mac today. Android is in the works." · "It stays there unless you turn on sync."

## Beat sheet (45 seconds, 1350 frames)

| # | Time | Frames | Beat | iPhone clip | iPad clip (16:9 only) |
| --- | --- | --- | --- | --- | --- |
| 1 | 0:00 to 0:03 | 0 to 90 | Hook: mark and headline on paper | none (title card) | none |
| 2 | 0:03 to 0:09 | 90 to 270 | Problem: four quadrants, two questions | `iphone-matrix` | `ipad-matrix` |
| 3 | 0:09 to 0:18 | 270 to 540 | Feature 1: capture with shorthand | `iphone-capture` | `ipad-capture` |
| 4 | 0:18 to 0:26 | 540 to 780 | Feature 2: swipe to complete | `iphone-complete` | `ipad-complete` |
| 5 | 0:26 to 0:33 | 780 to 990 | Feature 3: dashboard | `iphone-dashboard` | `ipad-dashboard` |
| 6 | 0:33 to 0:40 | 990 to 1200 | Cross-platform: iPhone, iPad, Mac, web, Android coming soon | `iphone-widget` | `ipad-drag` |
| 7 | 0:40 to 0:45 | 1200 to 1350 | End card: lockup, gsdtaskmanager.com, platforms | none | none |

In 9:16 and 1:1 the iPhone clip carries every beat. In 16:9 both devices show the same beat, and the cross-platform beat pairs the Today's Focus widget on iPhone with the drag across quadrants on iPad.

## Voiceover script

Read at a calm pace, about 150 words per minute (115 words). No voiceover file exists in the repo today, so this is the read for a later recording. The beat sheet times the captions and doubles as this script's timing.

> Every to-do list says everything is urgent.
>
> GSD asks two questions: is it urgent, and is it important? The answers sort every task into four quadrants.
>
> Capture takes one line. Two exclamation points mean do first, a hashtag adds the tag, and it lands in the right quadrant.
>
> Swipe to finish. GSD celebrates for a second, then gets out of the way.
>
> The dashboard shows honest progress: what you finished, what is overdue, and how each quadrant is doing.
>
> It runs on iPhone, iPad, Mac, and the web, with Android coming soon. Tasks stay on your device unless you turn on sync.
>
> It's free and needs no account. Get the right things done at gsdtaskmanager.com.

## On-screen captions

| Beat | Caption | Notes |
| --- | --- | --- |
| 1 Hook | **Get the right things done.** | Landing page headline, verbatim. "right" and "done" italic in rust, as on the site. |
| 2 Problem | Two questions sort every task into four quadrants. | |
| 3 Capture | Capture in one line. | Second line shows the grammar as mono chips: `!!` Do First · `#home` tag |
| 4 Complete | Swipe to finish. | |
| 5 Dashboard | See what you finished and what is overdue. | |
| 6 Cross-platform | iPhone · iPad · Mac · Web · Android coming soon | Second line: Your tasks stay on your device unless you turn on sync. |
| 7 End card | GSD Task Manager lockup · gsdtaskmanager.com · iPhone · iPad · Mac · Web · Android coming soon | Optional small line: Free · Private · No sign-up (site tagline, verbatim) |

## Simulator flows to record

Devices, from `xcrun simctl list devices available`:

| Role | Device | Runtime | UDID |
| --- | --- | --- | --- |
| iPhone | iPhone 17 Pro | iOS 26.5 (23F77) | `F1F0563B-B96A-4EA3-BD4C-8B5D5A46841D` |
| iPad | iPad Pro 13-inch (M5) | iOS 26.5 (23F77) | `1AB77A4E-8576-4B71-BAE7-0BC00A58D352` |

Xcode 26.6 (17F113). Light appearance (the brand guide is light first; dark is adaptive, not preferred).

Demo data: the app already ships a demo harness, so this needs no new launch argument.

- `--demo-seed` wipes the store, loads fixed realistic tasks, and skips onboarding (`App/Support/DemoSeed.swift`).
- `--demo-clock <epoch>` freezes "now". The video uses `1789146000` (Friday 2026-09-11 17:00 UTC, noon Central) so relative dates and the trend chart read current.
- `--demo-appearance light` forces the scheme.
- `--demo-home` renders the real Today's Focus widget on a simulated Home Screen (`App/Demo/DemoHomeScreen.swift`).

XCUITest drives every flow from the existing `GSDScreenshotTests` target (`ScreenshotTests/DemoChoreography.swift`), which already has scene routing, accessibility identifiers, and the swipe and drag beats. The change adds a `video-*` scene family to that file. Each scene: launch seeded, wait for the UI, write a ready marker on the host, hold 1 second, run the beat, hold 1 second.

| Clip | Device | Length | Steps |
| --- | --- | --- | --- |
| `iphone-matrix` | iPhone | ~7 s | Hold on Do First, slow scroll through Schedule, Delegate, Eliminate, scroll back, hold |
| `iphone-capture` | iPhone | ~9 s | Tap capture, type "Call the plumber", pause, " !!" (chip turns Do First), pause, " #home" (tag chip), pause, Return, card lands in Do First, hold |
| `iphone-complete` | iPhone | ~8 s | Swipe "Reply to the investor email" right, tap Complete, confetti, hold |
| `iphone-dashboard` | iPhone | ~7 s | Tap Dashboard, charts animate in, slow scroll to the rings, hold |
| `iphone-widget` | iPhone | ~7 s | `--demo-home`: the Today's Focus widget settles on the Home Screen, hold |
| `ipad-matrix` | iPad | ~7 s | Hold on the 2x2 board in the split view |
| `ipad-capture` | iPad | ~9 s | Same capture beat as iPhone |
| `ipad-complete` | iPad | ~8 s | Same complete beat (iPad reveal button) |
| `ipad-dashboard` | iPad | ~7 s | Sidebar Dashboard, charts animate, hold |
| `ipad-drag` | iPad | ~8 s | Long-press "Finish the Q3 board deck", drag from Do First into Schedule, drop, hold |

iPad orientation: the split view reads best in landscape. `simctl recordVideo` captures the portrait framebuffer, so a landscape run records sideways. The plan is to rotate the clip 90 degrees with ffmpeg and confirm the result frame by frame. If that fails, the iPad records portrait, which still shows the full 2x2 board.

Recording: `xcrun simctl io <udid> recordVideo --codec h264 --mask ignored captures/<device>-<flow>.mov` in the background, stopped with SIGINT after the test ends. Status bar: `simctl status_bar override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`. Normalize: `ffmpeg -r 30 -c:v libx264 -pix_fmt yuv420p` at native resolution, trimmed to the flow window, verified with ffprobe.

## Remotion plan (Phase 3)

- Scaffold `./video` with the Remotion plugin (`npx create-video@latest --yes --blank --no-tailwind`), clips in `public/captures`.
- One `GSDVideo` component with an `aspect` prop; compositions `GSD16x9`, `GSD9x16`, `GSD1x1`, each 1350 frames at 30 fps.
- Clips through `OffthreadVideo`, framed with the brand card radius (22 pt continuous, scaled) and the brand card shadow `0 1px 2px rgba(40,33,22,.05), 0 8px 24px rgba(40,33,22,.06)`. No fake bezels.
- Tokens from `https://gsdtaskmanager.com/design.html`: paper `#F4F1E9`, sunken `#ECE7DC`, surface `#FFFFFF`, hairline `#E3DDD0`, ink `#211E1A`, ink-2 `#6E6760`, ink-3 `#797368`, rust `#B23A2E`, tide `#2C6680`, ochre `#8A6A22`, slate `#6F685F`, success `#3E7D52`. Spacing on the 4-pt grid (4, 8, 12, 16, 20, 24, 32).
- Type: the brand serif stack is `ui-serif, "New York", Georgia`. Headless Chrome cannot reach New York by name, so the video uses Newsreader, which gsdtaskmanager.com and the web app self-host as the cross-platform stand-in (weights 400 to 600, italic). Body and labels use the system sans stack, which resolves to SF on the rendering Mac.
- Captions animate with `spring()` and staggered delays, inside a safe area of at least 5 percent per edge (more at the bottom in 9:16 for platform UI overlays).
- Audio: `ffmpeg -i docs/assets/music.mp4 -vn -c:a aac -ar 44100 video/public/music.m4a`, trimmed to 45 s with a 2 s fade out. No `voiceover.mp3` exists, so the music runs at full level. If one appears at `video/public/voiceover.mp3`, the composition mixes it on top with the music at low level and the captions get retimed.
- End card: `Design/gsd-brand/gsd-lockup-horizontal.svg` (paths only, no font dependency), `gsdtaskmanager.com`, platform labels, "Android coming soon".

## Repo changes (kept small)

- `ScreenshotTests/DemoChoreography.swift`: add the `video-*` scenes (about 80 lines). No new file, so `project.yml` and the generated project stay untouched, and the owner's uncommitted build-number bump stays out of this branch's commits.
- `video/`: the Remotion project, plus `video/scripts/capture.sh` (boot, status bar, record, run test, normalize).
- `captures/` and `out/`: generated media, added to `.gitignore`.

## Open questions for the owner

1. The iPhone cross-platform shot uses the simulated Home Screen with the real Today's Focus widget (`--demo-home`), the same device the June marketing video used. Acceptable, or prefer a real app screen there?
2. Mac and web appear as labels only. A Mac Catalyst capture needs Screen Recording permission in your GUI session (`scripts/record-demos.sh mac` already exists). Want that as an add-on, or labels only?
3. No voiceover exists. Proceed music-only, or record the script first so the captions time to your read?
