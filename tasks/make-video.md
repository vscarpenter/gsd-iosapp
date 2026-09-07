Build a 45-second product video for GSD Task Manager in three aspect ratios, using Simulator footage you capture yourself. Apply the vinny-voice skill to every word on screen and in the voiceover script. Use the Remotion plugin for all Remotion work.

## Context
- GSD Task Manager is a native iPhone, iPad, and Mac universal app plus a web app. Android is coming soon.
- This repo is the Xcode project.
- Brand guide: https://gsdtaskmanager.com/design.html. Fetch it and take colors, type, and spacing from it. Do not guess.
- Landing page and CTA: https://gsdtaskmanager.com
- Deliverables: out/gsd-16x9.mp4 (1920x1080), out/gsd-9x16.mp4 (1080x1920), out/gsd-1x1.mp4 (1080x1080). All 30 fps, H.264 video, AAC audio.

## Phase 1: Plan and confirm
Read the project and list the app's main user flows. Write a 45-second beat sheet: a 3-second hook, the problem, three features, one cross-platform beat (iPhone, iPad, Mac, web, Android coming soon), and a closing CTA. Write the voiceover script at about 110 words and the on-screen captions. Show me the beat sheet, the script, and the Simulator flows you plan to record. Stop and wait for my approval before recording anything.

## Phase 2: Capture footage from the Simulator
1. Boot the newest iPhone Pro and iPad Pro simulators available. Use `xcrun simctl list devices` and tell me which devices and runtimes you chose.
2. Set the status bar on each: `xcrun simctl status_bar <udid> override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4`. Use light appearance unless the brand guide says otherwise.
3. Seed demo data. If the app already has a demo-data launch argument or scheme, use it. If not, add a `-demoMode` launch argument that loads realistic sample tasks. Keep that change small and reviewable.
4. Drive each flow with an XCUITest so the taps are repeatable. If the project has no UI test target and adding one is heavy, propose Maestro and wait for my answer before installing anything.
5. Record each flow with `xcrun simctl io <udid> recordVideo --codec h264 --mask ignored captures/<device>-<flow>.mov` running in the background. Run the test, then stop the recording with SIGINT. One clip per feature, 6 to 10 seconds each, with a one-second hold at the start and end.
6. Normalize the clips with ffmpeg: constant 30 fps, H.264, yuv420p, native resolution. Confirm each with ffprobe and report width, height, fps, and duration.

## Phase 3: Build the Remotion project
1. Create the project in ./video with the Remotion plugin. Put the clips in public/captures.
2. Write one shared Video component that takes the aspect ratio as a prop. Register three compositions: GSD16x9 (1920x1080), GSD9x16 (1080x1920), and GSD1x1 (1080x1080), each 45 seconds at 30 fps. Layout adapts per ratio: iPhone and iPad side by side in 16:9, a single centered iPhone in 9:16, and a centered device in 1:1. Never letterbox.
3. Use OffthreadVideo for the clips. Frame them with rounded corners and a soft shadow from the brand guide. Skip fake device bezels.
4. Animate the approved captions with spring easing and staggered timing. Use the brand font and colors. Keep captions inside the safe area for each ratio.
5. Audio: the music track is at docs/assets/music.mp4 in this repo. Extract the audio with ffmpeg to video/public/music.m4a (AAC, 44.1 kHz), confirm its duration with ffprobe, and trim or fade it to 45 seconds with a two-second fade out. If public/voiceover.mp3 exists, use it and time the captions to it, and mix the music under it at a low level. If there is no voiceover, run the music at full level and tell me.
6. End card: logo, gsdtaskmanager.com, and platform labels for iPhone, iPad, Mac, and web, with "Android coming soon."

## Phase 4: Render and verify
1. Render all three compositions to out/.
2. Verify each file with ffprobe: exact dimensions, 30 fps, 45 seconds, and audio present when expected.
3. Extract a frame every 3 seconds with ffmpeg, inspect the frames, and fix anything clipped, misaligned, or off-brand. Re-render and re-check. Report what you fixed.
4. Give me the three file paths, the final script, and a short list of anything you could not verify.

## Rules
- Ask before installing anything outside the repo, including Maestro or Homebrew packages.
- Do not publish, upload, or post anything.
- Keep app code changes limited to demo data and the UI test target, on a branch named video/product-demo.
- Every on-screen claim must match the shipped app. If a flow does not work, tell me instead of faking it.
