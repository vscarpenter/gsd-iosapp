# GSD product video (45 s, three aspect ratios)

Branch: `video/product-demo`. Spec: `docs/superpowers/specs/2026-09-07-product-video-design.md`.

## Phase 1: plan and confirm
- [x] Read the project, list user flows, fetch the brand guide and landing page
- [x] Beat sheet, voiceover script, captions, flows, devices (in the spec)
- [x] Voice verification pass on the script and captions
- [x] Owner approval given 2026-09-07: widget beat OK, Mac/web labels only, music only

## Phase 2: capture footage
- [x] Add `video-*` scenes to `ScreenshotTests/DemoChoreography.swift`
- [x] `scripts/capture-video-clips.sh`: boot, status bar, record, run test, stop, normalize, probe
- [x] Record 5 iPhone clips + 5 iPad clips (6 to 10 s, 1 s holds); all scenes pass
- [x] iPad landscape: records sideways, `transpose=2` rotates upright (verified)
- [x] Seed backdates createdAt so the dashboard trend reads naturally (re-recorded)
- [x] Normalize with ffmpeg (30 fps, H.264, yuv420p, native size); ffprobe report matches the trim table
- [x] Commit choreography + seed + capture script

## Phase 3: Remotion project
- [x] Scaffold `./video` with the plugin; clips in `public/captures`
- [x] Extract music to `video/public/music.m4a` (45.000 s, AAC 44.1 kHz, 2 s fade)
- [x] Shared `GSDVideo` component with `aspect` prop; three compositions
- [x] Captions with spring easing and stagger; brand font and tokens; safe areas (tests green)
- [x] End card (lockup, gsdtaskmanager.com, platforms, Android coming soon)
- [x] Layout stills reviewed (21 stills, 3 transition sequences); no layout fixes needed
- [x] Commit (`6af494f`)

## Phase 4: render and verify
- [x] Render three compositions to `out/`
- [x] ffprobe each: dimensions, 30 fps, 45 s, AAC audio present
- [x] Frame every 3 s; inspected all three sheets
- [x] Fix: `--color-space bt709` so the output is standard yuv420p (first render was yuvj420p)
- [ ] Final render + verify + Mac Catalyst build (running)
- [ ] Commit render/verify scripts; report paths, final script, unverifiable items

## Resuming from here
- Done: everything through the final render; branch pushed, PR #17 open (landing page swap: gsdtaskmanager.com PR #2)
- Deliverables: `out/gsd-16x9.mp4`, `out/gsd-9x16.mp4`, `out/gsd-1x1.mp4` (gitignored, regenerate with `video/scripts/render.sh`)
- Next: owner reviews and merges both PRs, then deploys the landing page with `./deploy.sh`
- Not verified: real-device playback, the Newsreader stand-in against New York on an Apple screen, audio level taste
- Owner's own uncommitted build-number bump (project.yml/pbxproj) and staged skill files were left untouched
