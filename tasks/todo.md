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
- [ ] Record 5 iPhone clips + 5 iPad clips (6 to 10 s, 1 s holds)
- [ ] Verify iPad landscape rotation trick; fall back to portrait if needed
- [ ] Normalize with ffmpeg (30 fps, H.264, yuv420p, native size); ffprobe report
- [ ] Commit choreography + capture script

## Phase 3: Remotion project
- [ ] Scaffold `./video` with the plugin; clips in `public/captures`
- [ ] Extract music to `video/public/music.m4a`; ffprobe duration; 45 s trim + 2 s fade
- [ ] Shared `GSDVideo` component with `aspect` prop; three compositions
- [ ] Captions with spring easing and stagger; brand font and tokens; safe areas
- [ ] End card (lockup, gsdtaskmanager.com, platforms, Android coming soon)
- [ ] Commit

## Phase 4: render and verify
- [ ] Render three compositions to `out/`
- [ ] ffprobe each: dimensions, 30 fps, 45 s, audio present
- [ ] Frame every 3 s; inspect; fix; re-render; re-check
- [ ] Report paths, final script, unverifiable items

## Resuming from here
- Done: research, spec, branch created (nothing committed yet)
- Next: wait for owner approval of the spec's beat sheet, script, and flows
- Blockers: three open questions in the spec (widget beat, Mac/web footage, voiceover)
- Assumptions: light appearance; iPhone 17 Pro + iPad Pro 13-inch (M5) on iOS 26.5; Newsreader stands in for New York; music-only audio
