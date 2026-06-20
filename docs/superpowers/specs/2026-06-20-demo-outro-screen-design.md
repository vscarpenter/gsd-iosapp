# Demo hero — branded ending screen (outro card)

Adds a short, branded **ending screen** to the marketing hero produced by the demo-video pipeline
(`scripts/encode.sh`). The outro shows the GSD quadrant mark, the wordmark **"GSD Task Manager"**,
and the landing-page URL **gsdtaskmanager.com**, then the clip ends (or loops back) on the brand card.

> Builds on `docs/superpowers/specs/2026-06-20-demo-video-pipeline-design.md`.

## Scope

- **Marketing hero only** (`build/demos/out/gsd-demo.mp4` · `gsd-demo.webm`). This footage is for the
  landing page at <https://gsdtaskmanager.com>, **not** the App Store / Mac App Store previews.
- App-Store previews (`iphone-6_9.mp4` · `ipad-13.mp4` · `mac.mp4`) are **left unchanged** — Apple's
  preview rules discourage end-cards/marketing overlays, and these go straight to the stores.

## What it looks like

A centered vertical stack on the brand paper background (cream in light, dark paper in dark):

1. The **quadrant mark** — the four rounded tiles (rust / teal / gold / gray) with the white check on
   the Do-First tile, identical pigments to `Design/icon/app-icon{,-dark}.svg`.
2. **"GSD Task Manager"** in the editorial serif (New York → Georgia → Times fallback), brand ink.
3. **gsdtaskmanager.com** in the system sans, in the teal accent (reads as the "link").

The hero crossfades into the card; the card's content gently fades up over the paper, then holds.

## How it's built (no `drawtext`)

The pipeline's ffmpeg has **no libfreetype**, so text can't be drawn in ffmpeg. Instead:

1. `scripts/assets/outro-card.svg.tmpl` is a transparent, square (1080×1080) SVG with color tokens
   (`__RUST__`, `__TEAL__`, `__GOLD__`, `__GRAY__`, `__TITLE__`, `__URL__`). Text is real vector text
   in the SVG (crisp at any scale, no font baked into the repo).
2. `encode.sh` substitutes the appearance-appropriate palette, renders the SVG → PNG with
   **`rsvg-convert`** (fallback: ImageMagick `magick`/`convert`) at the card size.
3. ffmpeg builds the outro segment with **core filters only**: a `color` source at the hero's exact
   `WxH`/fps as the paper background, the card `overlay`-ed centered with an alpha `fade` in, then
   `xfade` from the trimmed hero into the outro.

If neither `rsvg-convert` nor ImageMagick is present, the outro is **skipped with a NOTE** and the
plain hero is produced — the pipeline still works on a bare ffmpeg install.

## Card adapts to any aspect

The card is a fixed square overlaid centered on a paper background sized to the hero's frame, scaled
to `0.82 × min(W, H)`. Portrait heroes get paper bands top/bottom; the card never overflows. This
reuses the existing brand-paper letterbox approach (the `PAPER` pad on the Mac preview).

## Flags (added to `encode.sh`)

| Flag | Default | Meaning |
| --- | --- | --- |
| `--outro` / `--no-outro` | **on** | Append / skip the branded ending screen (hero only). |
| `--outro-dur S` | `3.5` | Seconds the ending screen holds (incl. crossfade). |
| `--outro-xfade S` | `0.6` | Crossfade duration from the demo into the card. |

`--outro` and `--loop-xfade` are mutually exclusive (a fixed ending vs. a seamless head→tail loop);
if both are given, the outro wins and a NOTE is printed.

## Determinism / brand

- Palette and paper colors are pinned per appearance, taken verbatim from the app-icon SVGs.
- The card is pure vector → identical render every run on a given machine; font substitution (New York
  vs. Georgia vs. Times) only shifts kerning slightly and never changes layout or color.

## Prerequisite (optional)

`brew install librsvg` (provides `rsvg-convert`) — or ImageMagick. Only needed for the outro; the rest
of the pipeline remains stock-ffmpeg-only.
