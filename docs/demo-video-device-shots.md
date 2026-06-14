# GSD demo video — device shot list

Record these 2 (optionally 3) clips on your iPhone, then AirDrop them to the Mac into
`build/demo/device/` with the exact filenames below. Keep the phone vertical. Use
Control Center's screen record (red dot). Leave ~2s of stillness at the start and end of each.

## 1. Widgets → `widgets.mov` (~10s raw)
Before recording: add the **Today's Focus** widget to both your Home Screen and a Lock
Screen. Have a few tasks due so it isn't empty.
Record: start on the Home Screen showing the widget (hold ~3s) → raise-to-wake / swipe to
the Lock Screen showing the widget there (hold ~3s).

## 2. Siri → `siri.mov` (~9s raw)
Record: from the Home Screen, say **"Hey Siri, add buy milk to GSD."** Let Siri's
confirmation show, then open GSD so the new task is visible in Do First (hold ~2s).
Speak clearly; retry if Siri mishears — we only need one clean take.

## 3. (Optional) Share sheet → `share.mov` (~8s)
Only needed if the in-app share auto-capture is dropped. In Safari, open any article →
Share → tap **GSD** → the compose sheet appears with the title prefilled → tap Add.

After dropping the files in, re-run `./scripts/build-demo.sh` (or
`FF=/usr/local/bin/ffmpeg bash scripts/build-demo.sh`) to fold them in. The script auto-detects
any file present in `build/demo/device/` and inserts that beat in storyboard order
(widgets after the dashboard, then share, then Siri, before the closing card).

## Music (optional)
Drop one royalty-free track at `assets/demo-music.mp3` (e.g. a CC0 track from Pixabay or
Uppbeat) and re-run the build; it's mixed in at -10 dB with a 2s fade-out. Leave it absent
for a music-free cut.
