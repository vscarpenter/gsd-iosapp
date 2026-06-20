# GSD demo-video pipeline

Repeatable, **automated** demo recordings of the native apps (iPhone · iPad · Mac) for two
destinations:

1. **Marketing site** (`gsdtaskmanager.com`) — one looping, **muted** hero clip.
2. **App Store / Mac App Store** app previews — one per device.

Footage is driven by an XCUITest over **seeded data with a frozen clock**, so re-recording after a
UI change produces identical motion. Nothing is hand-tapped.

> Design: `docs/superpowers/specs/2026-06-20-demo-video-pipeline-design.md`.

---

## Prerequisites

- **Xcode 26** with iOS 26 simulators: `iPhone 17 Pro Max` (6.9″ App-Store class) and
  `iPad Pro 13-inch (M5)`. The recorder auto-falls back to other Pro Max / 13″ models.
- **ffmpeg** (`brew install ffmpeg`) — stock build is fine; `encode.sh` uses no `drawtext`.
- **rsvg-convert** (`brew install librsvg`) — *optional*, only for the hero's branded ending card.
  ImageMagick (`magick`/`convert`) works as a fallback; if neither is installed the ending card is
  skipped (with a NOTE) and a plain hero is produced.
- For the **Mac** reel: grant **Screen Recording** permission to your terminal
  (System Settings ▸ Privacy & Security ▸ Screen Recording) and run it on a real Mac with a GUI
  session — `screencapture` can't run headless.
- The scripts are invoked with `bash` below (the repo may not carry the exec bit). To run them
  directly, `chmod +x scripts/record-demos.sh scripts/encode.sh` once.

## Quick start

```bash
# 1) Record raw reels (build/demos/raw/). Pick a device, and light|dark (default light).
bash scripts/record-demos.sh iphone light
bash scripts/record-demos.sh ipad   light
bash scripts/record-demos.sh mac    light      # real Mac only; see caveat
bash scripts/record-demos.sh all    dark       # all three, dark appearance

# 2) Encode the deliverables (build/demos/out/).
bash scripts/encode.sh --hero iphone                       # marketing hero (+ branded ending card)
bash scripts/encode.sh --hero iphone --no-outro            # hero without the ending card
bash scripts/encode.sh --hero iphone --outro-dur 4         # hold the ending card 4s (default 3.5)
bash scripts/encode.sh --hero iphone --loop-xfade          # seamless web loop (no ending card)
bash scripts/encode.sh --music path/to/track.m4a           # + music on the App-Store previews
```

The marketing hero **ends on a branded card** (logo · "GSD Task Manager" · gsdtaskmanager.com) by
default — it's for the landing page. The App-Store previews are deliberately left card-free. Use
`--no-outro` to drop it; `--outro` and `--loop-xfade` are mutually exclusive (a fixed ending vs. a
seamless loop — `--outro` wins).

Everything lands under **`build/demos/`**, which is gitignored — no video binaries are committed.

| Stage | Output dir |
| --- | --- |
| Raw captures | `build/demos/raw/{iphone,ipad}-{light,dark}.mp4`, `mac.mov` |
| Deliverables | `build/demos/out/` |

## Deliverables

**Marketing hero** (muted; comprehension must not depend on audio; ends on the branded card by
default — see *Ending card* below):

| File | Format |
| --- | --- |
| `gsd-demo.mp4` | H.264, yuv420p, `+faststart`, ~1280px long edge |
| `gsd-demo.webm` | VP9, ~1280px long edge |
| `gsd-demo-poster.png` | first frame (the matrix, not the ending card) |

**Per-device videos** (one per device; for the landing page — each **ends on the branded card** by
default, and may carry `--music`):

| File | Source device | Notes |
| --- | --- | --- |
| `iphone-6_9.mp4` | iPhone 17 Pro Max | native 1320×2868 (= Apple's 6.9″ class) |
| `ipad-13.mp4` | iPad Pro 13″ (portrait) | native 2064×2752 (= Apple's 13″ class) |
| `mac.mp4` | Mac Catalyst (screen capture) | scaled into 1920×1080 |

> **`mac.mp4` only exists once you record a Mac reel.** The simulator can't capture Mac Catalyst, so
> it must be recorded on a real Mac — see *The Mac video* below. With only iPhone/iPad reels present,
> `encode.sh` skips `mac.mp4` (with a NOTE) and produces the other two.

> **Reusing these as App-Store previews?** Re-run with `--no-outro` (Apple discourages end-cards on
> previews) and keep length ≤30s. Apple's accepted resolutions are strict and change with new device
> classes — verify before submitting:
> <https://developer.apple.com/help/app-store-connect/reference/app-preview-specifications/>

## Ending card (hero + every per-device video)

The hero **and each per-device video** finish on a branded card: the quadrant mark, **GSD Task
Manager** (editorial serif), and **gsdtaskmanager.com** on the brand paper background — the demo
crossfades into it, the card fades up, then holds. The card auto-sizes to `0.82 × min(W,H)` and
centers on paper bands, so it fits every aspect (portrait phone, portrait iPad, landscape Mac).
Use `--no-outro` to drop it everywhere (e.g. for App-Store previews).

- Source: `scripts/assets/outro-card.svg.tmpl` (transparent, square; color tokens substituted per
  light/dark from the app-icon palette). Text is real vector text — no font is committed.
- Since this ffmpeg has no `drawtext`, `encode.sh` rasterizes the SVG with `rsvg-convert` (fallback
  ImageMagick) and composites it with core filters (`color` + `overlay` + `xfade`).
- Knobs: `--no-outro`, `--outro-dur S` (default 3.5), `--outro-xfade S` (default 0.6).
- Design notes: `docs/superpowers/specs/2026-06-20-demo-outro-screen-design.md`.

## The Mac video

`mac.mp4` isn't produced by the iPhone/iPad runs — **Mac Catalyst is a native macOS app, so the iOS
simulator (`simctl`) can't capture it.** It must be recorded on a real Mac with `screencapture`,
which needs a GUI session and Screen Recording permission (won't run headless/CI). On your Mac:

```bash
# 1) Grant Screen Recording to your terminal: System Settings ▸ Privacy & Security ▸ Screen Recording.
# 2) Record the Mac reel (drives the reel-mac choreography while capturing the screen):
bash scripts/record-demos.sh mac light        # → build/demos/raw/mac.mov
# 3) Re-encode — mac.mp4 now gets the same branded ending card as the others:
bash scripts/encode.sh --hero iphone          # writes build/demos/out/mac.mp4 (+ hero, iphone, ipad)
```

`screencapture` records the **whole display** — there is no scriptable "capture just this app" mode
(and synthesizing ⌃⌘F into a Catalyst app from XCUITest does not reliably full-screen it). So for a
clean, app-only capture, **maximize the GSD window before recording**: click the green zoom button (or
double-click its title bar) so it fills the screen. macOS remembers the window size, so once maximized
it stays that way for later runs. `encode.sh` then scales the capture into 1920×1080, padding with
brand paper for the display aspect (e.g. cream bands above/below on a 21:9 ultrawide — they blend with
the app's paper background).

If the window wasn't maximized (GSD recorded small among your other windows), crop to it before
scaling with `--mac-crop w:h:x:y` (ffmpeg `crop` syntax). Grab a frame to measure pixels first:

```bash
ffmpeg -ss 20 -i build/demos/raw/mac.mov -frames:v 1 mac.png    # then read the window's x/y/w/h
bash scripts/encode.sh --mac-crop 2560:1440:440:0               # crop to that region, then scale
```

## The demo script (beats)

Driven by `ScreenshotTests/DemoChoreography.swift`, scenes `reel-iphone` / `reel-ipad` /
`reel-mac`, with deliberate ~0.8–1.2 s pauses so each action reads. Every reel **starts and ends on
the populated matrix** so the muted hero loops cleanly.

1. Open on the seeded matrix.
2. Type `Email the architect !! #work` in the capture bar — the quadrant chip recolors live, the tag
   chip appears.
3. Submit; the card drops into **Do First**.
4. Swipe a task to complete → green fill + confetti.
5. Platform beat:
   - **iPhone** (portrait): scroll the four quadrant sections, open a task, close.
   - **iPad** (portrait): the 2×2 board, then **drag a card across a quadrant boundary** to
     reclassify (Delegate → Do First).
   - **Mac**: **⌘K** command palette → run a smart view (“Today’s Focus”) → ⌘1 back to the matrix.

## Determinism

Same seed + frozen clock + forced appearance ⇒ identical footage every run.

- **Seed:** `App/Support/DemoSeed.swift` (`--demo-seed`) wipes the store and loads a fixed set of
  realistic tasks — varied titles, **varied due dates** (overdue / today / +2d / +1w), `#tags`,
  subtasks, a dependency, a recurring task, and a completed-history trend. Onboarding is skipped.
- **Clock:** `--demo-clock <epoch>` (the reels pass **1750420800** = 2025-06-20 12:00 UTC Fri) pins
  `TaskStore`/repositories *and* the relative due-date labels (via `\.demoClock` → `RelativeDate`)
  and the dashboard trend (`AnalyticsEngine`). Production keeps the live clock — these flags are
  no-ops unless passed, and only the choreography passes them.
- **Appearance:** `--demo-appearance light|dark` forces the color scheme.
- **Status bar:** `simctl status_bar override` pins 9:41 / full signal & battery (iOS reels).

## Accessibility identifiers added

The UI test touches elements by identifier. These were added to the SwiftUI views (all additive —
no layout/behavior change):

| Identifier | View |
| --- | --- |
| `capture-field`, `capture-quadrant-chip`, `capture-details` | `App/Matrix/CaptureBar.swift` |
| `task-card-<id>` | `App/Matrix/TaskCardView.swift` (root; `.combine` merges the disc in) |
| `task-editor`, `editor-save`, `editor-cancel` | `App/Editor/TaskEditorView.swift` |
| `palette-row-<title>` | `App/Palette/CommandPaletteView.swift` |

Some elements are reached by their (localized) label rather than an identifier, because SwiftUI
doesn't reliably expose identifiers on them:

- The **swipe-action “Complete” button** (List `.swipeActions` / the iPad hand-rolled reveal
  button) and the **palette search field** (`app.searchFields.firstMatch`, since `.searchable`
  doesn't bind a custom id).
- **iPad cards:** `task-card-<id>` surfaces inside the iPhone `List`, but the iPad `SwipeRevealRow`
  (custom drag/context-menu wrapping) hides the inner identifier, so the choreography falls back to
  matching the card's accessibility **label** (which begins with the task title). The drag drops
  onto a *card* in the destination quadrant — the drop still lands in that quadrant's
  `.dropDestination`. (A `quadrant-cell` container identifier was deliberately *not* used: on iPad
  it promoted the whole quadrant into one accessibility element, hiding the individual cards.)

### Why iPad is captured portrait

`simctl recordVideo` captures the device's **portrait framebuffer regardless of in-app rotation**,
so an `XCUIDevice` landscape flip records *sideways*. Portrait 13" (2064×2752) is itself an accepted
App-Store size and still shows the full 2×2 board in the split-view detail, so the iPad reel records
portrait. If you specifically need a landscape iPad preview, capture it on a real device via
QuickTime (which Apple prefers for previews anyway — see below).

## Manual steps you still own

1. **Music** (optional): supply a royalty-free track and pass `--music FILE`. The web hero stays
   muted regardless; only the App-Store previews get audio.
2. **App-Store previews on a real device** (see caveat): the simulator captures are ideal for the
   marketing site, but Apple expects previews shot on hardware. To produce those, drive the same
   flow on a connected device while recording with QuickTime:
   - Connect the iPhone/iPad, open **QuickTime Player ▸ File ▸ New Movie Recording**, and select the
     device as the camera source.
   - Run the reel against the device:
     `xcodebuild test-without-building -scheme GSDScreenshots -destination 'platform=iOS,name=<device>' -only-testing:GSDScreenshotTests/DemoChoreography/testDemoScene` with
     `TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE=reel-iphone` (the UI test still drives every beat).
   - Trim the QuickTime clip to 15–30 s and run it through `encode.sh` (drop it in `build/demos/raw/`).
3. **Mac**: run `bash scripts/record-demos.sh mac` locally (needs Screen Recording permission). The
   full-screen capture is scaled into 1920×1080 by `encode.sh`; tighten the crop there if you want a
   windowed frame.

## Caveats

- **Simulator previews may be rejected by App Store review.** Apple expects app previews captured on
  a **real device**. Use the simulator path for the marketing hero; use the QuickTime real-device
  route above for the store previews.
- **Mac can't use `simctl`.** Mac Catalyst is a native macOS app (no simulator), so it's captured
  with `screencapture -v` — which is a real-machine capture and therefore valid for the Mac App
  Store. It needs Screen Recording permission and a GUI session (won't run headless/CI).
- **Scheme:** the reels run under the existing **`GSDScreenshots`** scheme (no separate demo scheme).

## Follow-up: marketing screenshot gallery (proposed)

The marketing site also has a screenshot gallery. A natural next step is a **Fastlane `snapshot`**
setup: a `Snapfile` driving the same seeded, frozen-clock launch across device/locale matrices to
emit stills automatically (reusing the accessibility identifiers above). Tracked as a separate
spec — not built here.
