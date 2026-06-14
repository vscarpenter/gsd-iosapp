# Marketing Demo Video — Design Spec

**Date:** 2026-06-14
**Status:** Approved (user waived written-spec review gate)
**Goal:** Produce a polished ~75–85s landscape marketing/social demo video for GSD that
shows the core task flow plus the platform features that make it useful — widgets, share
sheet, and Siri — and delivers a finished, captioned MP4 with a music bed.

## Locked decisions

| Decision | Choice |
| --- | --- |
| Purpose | Marketing / social demo (website, X/LinkedIn, YouTube) |
| Format | Landscape **16:9, 1920×1080 @ 30fps**, target **75–85s** |
| Audio / edit | On-screen caption cards + royalty-free music bed; **I deliver a finished MP4** (ffmpeg assembly) |
| Capture | **Hybrid** — in-app clips auto-recorded on the Simulator; 2 short clips shot by the owner on a physical device (Siri voice, Home/Lock-Screen widgets) |
| Composition | **Approach A** — vertical phone screen on a cream backdrop with a serif caption panel beside it |

## Brand tokens (from `claude-design-ios/styles/tokens.css`, `PRODUCT.md`)

Editorial calm, rationed color, type-led. No neon / glass / decorative gradient.

- Paper (light bg): `#F4F1E9` · Ink (text): `#17150F` · White: `#FFFFFF`
- Quadrant accents (the *only* strong color): Do First `#B23A2E` (rust) · Schedule `#2C6680` (tide) · Delegate `#8A6A22` (ochre) · Eliminate `#6F685F` (slate)
- Type: **serif display** for titles/feature labels (Charter or Georgia — confirm a `.ttf`/`.ttc` path on the build Mac at assembly), system sans for sub-captions.
- Icon source: `Design/icon/app-icon.svg` (+ `launch-mark.svg`), rasterized for the title/CTA cards.

## 16:9 composition (Approach A)

Canvas 1920×1080, cream `#F4F1E9` fill.

- Phone clip (886×1920) scaled to **~1000px tall** (≈462px wide), rounded corners (~r48) + soft drop shadow, anchored left: ~x=240, vertically centered (y≈40).
- Right panel (~x=780 → 1820): per-beat **serif feature label** (ink) + a smaller sans **sub-caption**; a thin vertical rule in that beat's **quadrant accent** for color.
- Title / CTA beats are full-canvas cards (no phone), same paper/ink/serif system.
- Transitions: 8–12 frame crossfades between beats; gentle, no flashy wipes.

## Storyboard (≈74s core; ⌘K palette beat optional)

| # | Beat | Source | ~Dur | Serif label / sub-caption | Action on screen |
| --- | --- | --- | --- | --- | --- |
| 0 | Title | generated | 4s | "GSD" / "The calm way to get stuff done" | App icon on cream |
| 1 | Frictionless capture | sim-auto | 11s | "Capture in plain language" / "`!!` sets priority · `#tags` organize" | Type *Call my wife !! #family*; quadrant pill + tag chip react; lands in Do First |
| 2 | The matrix | sim-auto | 10s | "Urgency × importance" / "Four quadrants, always in view" | Show 4 quadrants; move a task between two |
| 3 | Complete + confetti | sim-auto | 5s | "Done feels good" / — | Swipe to complete → confetti |
| 4 | Organize | sim-auto | 9s | "Built for real work" / "Tags · subtasks · recurring · dependencies" | Browse tab; filter by tag; open a task showing subtasks/recurrence |
| 5 | Analyze | sim-auto | 8s | "See where your effort goes" / "Insights, on-device" | Dashboard; charts animate in |
| 6 | Widgets | **device clip** | 8s | "Always one glance away" / "Today's Focus on Home & Lock Screen" | Home-Screen widget + Lock-Screen widget |
| 7 | Share sheet | sim-auto\* | 6s | "Add from anywhere" / "Share into GSD from any app" | Share a link from Safari → GSD compose |
| 8 | Siri | **device clip** | 7s | "Just ask Siri" / "Hands-free capture" | *"Hey Siri, add buy milk to GSD"* → task created |
| 9 | Close / CTA | generated | 6s | "Offline-first · Private by default · No account needed" / "GSD — on the App Store" | Logo + URL |

**Optional ⌘K beat** (~5s, "Do anything, fast", iPad/hardware-keyboard) slots before #6; first to cut if over length.

## Build plan

### 1. Demo seed dataset
Curated `TaskStore` seed used by every sim scene (and reusable by the existing screenshot harness). Requirements:
- All four quadrants populated with realistic, screenshot-safe titles (no PII).
- A few tags (e.g. `#family`, `#work`, `#errands`) so filtering reads clearly.
- Enough **completed** history (varied dates) that Dashboard charts render with real shape.
- One **recurring** task and one task with **subtasks + a dependency** for the Organize beat.
- `hasOnboarded=true` in App-Group defaults (harness already expects pre-seed + onboarded).

### 2. Sim capture harness
Extend the proven `ScreenshotTests/PreviewChoreography.swift` pattern:
- Per-scene XCUITest flows selected by a `SCENE` env var (`capture`, `matrix`, `complete`, `organize`, `dashboard`, `share`), each a deterministic, paced flow (reuse the existing `pause()` cadence so tokens/animations read on video).
- `scripts/record-demo.sh` loops the scenes: boot a known sim (iPhone, native 886×1920), seed the DB, then for each scene run `xcrun simctl io <sim> recordVideo` around the gated test, writing `build/demo/clips/<scene>.mp4`.
- Independent clips → easy re-takes and frame-accurate cutting. Gated by a `DEMO=1`-style env so normal `GSDScreenshots` runs skip them.

### 3. Device shot list (owner records)
One-page guide `docs/demo-video-device-shots.md` covering the 2 device clips:
- **Widgets:** add the Today's Focus widget to Home Screen + Lock Screen ahead of time; screen-record a slow pan Home → Lock; ~8s.
- **Siri:** exact phrase *"Hey Siri, add buy milk to GSD"*; show the Siri confirmation + the task appearing; ~7s.
- How to capture (Control Center screen record), keep it vertical, and AirDrop the `.mov` to the Mac into `build/demo/device/`.

### 4. ffmpeg assembly
`scripts/build-demo.sh`:
- Generate title / per-beat caption / CTA assets (serif drawtext on cream, or pre-rendered PNG overlays).
- Composite each phone clip into the 16:9 frame (scale + rounded-corner mask + shadow + caption panel).
- Normalize device `.mov` clips to the same canvas/fps.
- Concatenate beats with short crossfades; mix the music bed (single swappable input); export `build/demo/gsd-demo-16x9.mp4`.

## Deliverables
- `build/demo/gsd-demo-16x9.mp4` — final video.
- `scripts/record-demo.sh`, `scripts/build-demo.sh` — reproducible pipeline.
- `ScreenshotTests/DemoChoreography.swift` (or extended `PreviewChoreography`) — sim scenes.
- `docs/demo-video-device-shots.md` — owner's device shot list.
- Demo seed dataset (in the harness).

## Open items (resolve before final render)
- **Share-sheet sim clip (#7)** is the one technically risky auto-capture (cross-app Safari → system share sheet → GSD). Attempt sim-auto first; clean fallback is to make it a 3rd device clip. Does not block the rest of the pipeline.
- **Music bed** — owner supplies one `.mp3` (or points at a Pixabay/Uppbeat CC0 track); assembly treats it as a single swappable input. First cut may render music-free if the track is chosen after seeing picture.

## Success criteria
- Single 16:9 MP4, 75–85s, brand-accurate (paper/ink/serif, rationed accent color), captions legible at small sizes (silent-autoplay safe).
- Shows: capture w/ live parsing, the matrix, complete+confetti, organize (tags/subtasks/recurring/deps), dashboard, widgets, share, Siri, privacy/offline CTA.
- Reproducible: re-running the two scripts (plus dropping in fresh device clips + music) regenerates the video.
