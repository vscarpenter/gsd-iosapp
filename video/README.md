# GSD product video

A 45-second product video for GSD Task Manager, built with Remotion in three cuts: 16:9
(1920x1080), 9:16 (1080x1920), and 1:1 (1080x1080), all 30 fps, H.264 video, AAC audio.
The beat sheet, script, and captions are in
`../docs/superpowers/specs/2026-09-07-product-video-design.md`.

## Regenerate the media (not committed)

```bash
# Simulator clips: records the video-* scenes, normalizes them, prints an ffprobe report.
bash ../scripts/capture-video-clips.sh build
bash ../scripts/capture-video-clips.sh record iphone
bash ../scripts/capture-video-clips.sh record ipad
bash ../scripts/capture-video-clips.sh normalize && bash ../scripts/capture-video-clips.sh probe
cp ../captures/normalized/*.mp4 public/captures/

# Music: the first 45 s of ../docs/assets/music.mp4 with a 2 s fade out.
bash scripts/make-music.sh
```

## Work on it

```bash
npm i
npm test            # layout and timeline invariants (node --test)
npm run lint        # eslint + tsc
npx remotion studio # preview GSD16x9, GSD9x16, GSD1x1
```

## Render

```bash
bash scripts/render.sh          # ../out/gsd-16x9.mp4, gsd-9x16.mp4, gsd-1x1.mp4
bash scripts/render.sh GSD9x16  # one cut
```

## How it is put together

- `src/beats.ts` is the timeline: a 3 s hook, five beats (problem, capture, complete, dashboard,
  platforms), and a 5 s end card, plus which clip each device plays per beat.
- `src/layout.ts` is pure layout math per aspect ratio: safe areas, device rectangles at the
  clips' native ratio, and the caption band. `layout.test.ts` pins the invariants.
- `src/GSDVideo.tsx` composes `Hook`, `Stage` (device cards with crossfading `OffthreadVideo`
  clips and spring-animated captions), and `EndCard`, with the music underneath.
- `src/theme.ts` holds the brand tokens from gsdtaskmanager.com/design.html. Newsreader stands
  in for New York, as it does on the website.
