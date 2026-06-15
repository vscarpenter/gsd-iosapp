# GSD demo video — device shot list

Record these (optional) clips on your iPhone, then AirDrop them to the Mac into
`build/demo/device/` with the exact filenames below. Keep the phone vertical. Use
Control Center's screen record (red dot). Leave ~2s of stillness at the start and end of each.

> **The widgets beat is now simulated** — the Today's Focus widget on a faux Home Screen is
> recorded automatically on the Simulator (`App/Demo/DemoHomeScreen.swift`, scene `widgets` in
> `scripts/record-demo.sh`). No device widget recording is needed. Siri and Share stay optional
> below because they are inherently system features.

## 1. Siri → `siri.mov` (~10s raw)
Siri only fires on the app's **registered** phrases (see `App/Intents/GSDAppIntents.swift`):
"Add a task in GSD" / "Create a task in GSD". The task text is a follow-up, not part of the
phrase. "Add buy milk to GSD" will NOT work.

Most reliable for recording — **Type to Siri** (no voice-recognition risk):
1. Enable: Settings → Accessibility → Siri → **Type to Siri** (on iOS 26 it may live under
   Settings → Apple Intelligence & Siri → Type to Siri).
2. Start the screen recording, then hold the side button to summon Siri (a text field appears).
3. Type exactly: **Add a task in GSD** → send.
4. Siri asks for the task → type **Buy milk** → send.
5. Siri confirms *"Added buy milk to GSD."* Optionally open GSD so "Buy milk" shows in Do First.

Voice works too if you prefer: "Hey Siri, **Add a task in GSD**", then say "Buy milk" when asked.

## 2. (Optional) Share sheet → `share.mov` (~8s)
Only needed if the in-app share auto-capture is dropped. In Safari, open any article →
Share → tap **GSD** → the compose sheet appears with the title prefilled → tap Add.

After dropping the files in, re-run `./scripts/build-demo.sh` (or
`FF=/usr/local/bin/ffmpeg bash scripts/build-demo.sh`) to fold them in. The script auto-detects
any file present in `build/demo/device/` and inserts that beat in storyboard order
(share, then Siri, before the closing card).

## Music (optional)
Drop one royalty-free track at `docs/assets/demo-music.mp3` (e.g. a CC0 track from Pixabay or
Uppbeat) and re-run the build; it's mixed in at -10 dB with a 2s fade-out. Leave it absent
for a music-free cut.
