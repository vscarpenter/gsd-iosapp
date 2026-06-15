# Simulated "Today's Focus" Widget Beat — Design Spec

**Date:** 2026-06-15
**Status:** Approved (design approved in chat; written-spec review pending)
**Supersedes:** the real-device widget recording folded in by commit `f10db1c` (the device
`widgets.MP4`). See `2026-06-14-marketing-demo-video-design.md` for the parent design.

**Goal:** Replace the only real-device clip in the marketing demo (`build/demo/device/widgets.MP4`,
the Home/Lock-Screen widget recording) with a fully **simulator-recorded** scene showing the real
Today's Focus widget on a faux iOS Home Screen, so the entire video is reproducible from one
scripted pipeline with no physical-device step.

## Locked decisions

| Decision | Choice |
| --- | --- |
| Widget beat source | **Simulated in-app**, recorded on the Simulator like every other scene (not a device recording) |
| Scene look | **Faux iOS Home Screen** — wallpaper, status-bar time, the Today's Focus widget tile among generic app icons + a dock. Framed as a phone by `build-demo.sh` |
| Widget rendering | **Reuse the real `TodaysFocusView`** compiled into the app target (single source of truth), fed static demo data — not a replica |
| Widget size | **Medium** tile, near the top of the Home Screen |
| Caption | Unchanged: label *"Always one glance away"*, sub *"Today's Focus on your Home Screen"*, amber accent `#8A6A22` |
| Trademark | Generic colored rounded-square app icons only (GSD's own AppIcon may appear). **No third-party logos.** |

## Brand tokens (carried from the parent spec)

- Paper `#F4F1E9` · Ink `#17150F` · White `#FFFFFF`
- Widget-beat accent (Delegate/ochre): `#8A6A22`
- Wallpaper: a calm brand-tinted gradient (warm paper → slightly deeper warm tone), *not* the
  flat cream backdrop, so the white widget tile reads as a raised card.

## Components

### 1. `App/Demo/DemoHomeScreen.swift` (new, demo-gated)
A self-contained full-screen SwiftUI faux Home Screen. Unreachable in normal/App Store launches
— it renders only when the app is launched with `--demo-home`, which only the choreography test
passes (same gating discipline as `DemoSeed`).

- **Wallpaper:** calm brand-tinted vertical gradient.
- **Status bar:** a `9:41` time (and minimal trailing glyphs) for realism.
- **Widget tile:** a medium-proportioned rounded-rect card (white, soft shadow, ~16pt corner
  radius) wrapping the real `TodaysFocusView` with internal padding matching a system widget.
- **Demo data:** a static `WidgetSnapshot` whose three tasks reuse the seed's Do-First titles —
  *Get finance sign-off · Finish the Q3 board deck · Reply to the investor email* —
  `totalCount: 3` (no "+N more"). This narratively ties the widget to the earlier scenes; no
  `--demo-seed` / store / App-Group read is needed.
- **App grid + dock:** ~2 rows of generic colored rounded-square icons plus a 4-icon dock. The
  GSD AppIcon may appear among them. No third-party logos.
- **Motion:** on appear, a single calm ~0.6s fade+rise of the widget tile, then hold. No looping
  or parallax (brand = calm). An accessibility identifier (e.g. `demo-home-screen`) on the root
  lets the test wait for it.

### 2. Real widget view reused in the app target
Add `Widgets/TodaysFocusView.swift` and `Widgets/TodaysFocusEntry.swift` to the **GSD** target's
`sources` in `project.yml`. Both compile against GSDSnapshot (already an app dependency) + WidgetKit
(available to the app). In an app context `.widgetURL` is an inert no-op and `@Environment(\.widgetFamily)`
resolves to its default (medium → the 5-row path, fine with 3 tasks). **Fallback** (only if it
misrenders in-app): a ~15-line inline replica of the row layout inside `DemoHomeScreen`.

### 3. App routing — `App/GSDApp.swift`
In `body`'s `WindowGroup`, branch on `ProcessInfo.processInfo.arguments.contains("--demo-home")`:
show `DemoHomeScreen()` when present, else the existing `ContentView()` (with all its
`.environment`/`.task` modifiers). `DemoHomeScreen` needs none of that wiring.

### 4. Choreography — `ScreenshotTests/DemoChoreography.swift`
Add a `widgets` scene handled *before* the existing `--demo-seed` launch + tab-bar wait (the faux
Home Screen has no tab bar): launch with `["--demo-home"]`, wait for `demo-home-screen`, dwell ~6s
while the entrance settles, end. All existing scenes are untouched.

### 5. Pipeline wiring
- `scripts/record-demo.sh`: add `widgets` to `SCENES` → records `build/demo/clips/widgets.mp4`.
- `scripts/build-demo.sh`: **move** the widgets beat out of the optional device-clip section
  (`dev_clip widgets`) into the in-app `seg` section, sourcing `$CLIPS/widgets.mp4`
  (lead ≈ 0.5, dur ≈ 6), keeping the existing caption + amber accent. The `order` array already
  lists `widgets` after `dashboard`. The `siri`/`share` `dev_clip` hooks remain as inert optional
  legacy (absent → skipped).
- Delete local real footage: `build/demo/device/widgets.MP4` plus stale
  `seg/widgets.mp4.old` / `device/*.placeholder` artifacts. All under gitignored `build/` — local
  cleanup only; nothing to commit there.
- `docs/demo-video-device-shots.md`: drop the widgets recording instructions (now simulated);
  keep siri/share as the remaining optional device shots.

## What is explicitly out of scope (YAGNI)

- Siri and Share beats stay device-optional — they are inherently system features (Siri intent,
  the system share sheet) and are already absent from the cut. Not simulated here.
- No animated/looping Home Screen. One calm entrance, then hold.
- No real third-party app icons or wallpapers.

## Verification

1. `xcodegen generate` (picks up the new `--demo-home` routing + added widget sources).
2. Build GSD for **iPhone and iPad** simulators — both must compile clean (Swift 6 strict
   concurrency; the reused widget view must not trip `Sendable`/actor diagnostics in-app).
3. `cd GSDKit && swift test` — still green (no logic touched, but confirm nothing broke).
4. `scripts/record-demo.sh` on a booted sim → regenerates all clips including
   `build/demo/clips/widgets.mp4`.
5. `scripts/build-demo.sh` → `build/demo/gsd-demo-16x9.mp4`; eyeball the framed Home Screen beat
   for correct widget content, caption, timing, and that no real-device footage remains.
6. New source files get `.claude/decisions/*.log` entries per repo convention.

## Risks

- **WidgetKit view rendered outside a widget.** Low risk — `TodaysFocusView` is plain SwiftUI;
  the only widget-specific modifiers (`.widgetURL`, `Link`, `widgetFamily`) are inert or default
  cleanly in-app. Mitigation: the inline-replica fallback in §2.
- **`widgetFamily` default differs by OS.** Only affects `visibleCount` (3 vs 5); with 3 tasks the
  output is identical either way.
