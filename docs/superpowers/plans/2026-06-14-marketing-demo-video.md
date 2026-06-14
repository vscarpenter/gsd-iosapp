# Marketing Demo Video Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a finished ~75–85s landscape (16:9) marketing demo video for GSD by auto-recording in-app Simulator footage, compositing it onto a branded backdrop with caption cards + music, and integrating two owner-shot device clips (Siri, widgets).

**Architecture:** A launch-argument-gated demo seed (`--demo-seed`) populates the live `TaskStore` with curated data. Per-scene XCUITest flows in `DemoChoreography.swift` drive the seeded app deterministically; `scripts/record-demo.sh` wraps each scene in `simctl io recordVideo` to emit one clip per beat. `scripts/build-demo.sh` (ffmpeg) generates title/CTA/caption assets, composites each vertical clip onto a 1920×1080 cream backdrop, concatenates with gentle cream fades, and mixes the music bed.

**Tech Stack:** Swift 6 / SwiftUI, XCUITest, `xcrun simctl`, XcodeGen, ffmpeg 8.1.1, bash.

**Spec:** `docs/superpowers/specs/2026-06-14-marketing-demo-video-design.md`

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `App/Support/DemoSeed.swift` | Curated demo dataset + `--demo-seed`-gated seeding into `TaskStore` | Create |
| `App/GSDApp.swift` | Call `DemoSeed.seedIfRequested` after `store.start()` | Modify (`.task` block, ~line 121) |
| `ScreenshotTests/DemoChoreography.swift` | Per-scene XCUITest flows selected by `DEMO_SCENE` env | Create |
| `scripts/record-demo.sh` | Boot sim, build-for-testing, record one clip per scene | Create |
| `scripts/build-demo.sh` | ffmpeg: cards + 16:9 compositing + concat + music | Create |
| `docs/demo-video-device-shots.md` | Owner's shot list for the 2 device clips | Create |
| `build/demo/` | Output dir (clips, segments, device, final mp4) | Generated (gitignored) |

`ScreenshotTests/` is glob-sourced by the `GSDScreenshotTests` target in `project.yml`, so a new file there is picked up after `xcodegen generate`. No `project.yml` edit needed.

---

## Task 0: Preflight — verify toolchain & resolve names

**Files:** none (verification only)

- [ ] **Step 1: Confirm the screenshot scheme name and test target**

Run: `xcodebuild -list -project GSD.xcodeproj | sed -n '/Schemes/,$p'`
Expected: a scheme named `GSDScreenshots` is listed. (If the name differs, use that name everywhere `GSDScreenshots` appears below.)

- [ ] **Step 2: Resolve / boot an iPhone simulator and capture its UDID**

```bash
xcrun simctl list devices available | grep -E "iPhone 17 Pro \(" | head -1
# Boot it (note the UDID printed inside the parentheses above):
UDID=$(xcrun simctl list devices available | grep -E "iPhone 17 Pro \(" | head -1 | grep -oE "[0-9A-F-]{36}")
xcrun simctl boot "$UDID" 2>/dev/null; xcrun simctl bootstatus "$UDID" -b
echo "UDID=$UDID"
```
Expected: a 36-char UDID prints and the device reaches "booted".

- [ ] **Step 3: Confirm assembly assets exist (fonts + an app-icon PNG)**

```bash
ls -1 /System/Library/Fonts/Supplemental/Georgia.ttf /System/Library/Fonts/Supplemental/Arial.ttf
find App/Assets.xcassets -iname '*.png' -path '*AppIcon*' | head
command -v ffmpeg ffprobe
```
Expected: both fonts exist, at least one AppIcon PNG path prints, ffmpeg/ffprobe resolve. Record the icon PNG path for Task 4 (`ICON`). If Georgia is missing, substitute another serif TTF under `/System/Library/Fonts/Supplemental/` (e.g. `Times New Roman.ttf`).

---

## Task 1: Demo seed dataset + launch-argument hook

**Files:**
- Create: `App/Support/DemoSeed.swift`
- Modify: `App/GSDApp.swift` (the `.task { store.start() … }` block near line 121)

- [ ] **Step 1: Create the demo seed**

Create `App/Support/DemoSeed.swift`:

```swift
import Foundation
import GSDModel
import GSDStore

/// Debug-only demo fixtures for the marketing video. Runs ONLY when the app is launched with
/// the `--demo-seed` argument, which only `ScreenshotTests/DemoChoreography` passes — the app
/// itself never sets it, so this is unreachable in normal and App Store launches.
enum DemoSeed {
    static let launchArgument = "--demo-seed"

    static func seedIfRequested(_ store: TaskStore) async {
        guard ProcessInfo.processInfo.arguments.contains(launchArgument) else { return }
        UserDefaults(suiteName: AppGroup.id)?.set(true, forKey: "hasOnboarded")
        do {
            // Idempotent: clear any prior run so re-records are deterministic.
            for task in try await store.fetchAllTasks() { try await store.delete(task) }
            for task in fixtures() { try await store.create(task) }
        } catch {
            print("[DemoSeed] seeding failed: \(error)")   // best-effort; empty matrix is the worst case
        }
    }

    private static func fixtures() -> [Task] {
        let cal = Calendar.current
        let now = Date()
        func daysAgo(_ d: Int) -> Date { cal.date(byAdding: .day, value: -d, to: now)! }

        // urgent/important → quadrant: (T,T) Do First · (F,T) Schedule · (T,F) Delegate · (F,F) Eliminate
        func t(_ id: String, _ title: String, u: Bool, i: Bool,
               tags: [String] = [], recurrence: RecurrenceType = .none,
               subtasks: [Subtask] = [], deps: [String] = [],
               done: Date? = nil) -> Task {
            Task(id: id, title: title, urgent: u, important: i,
                 completed: done != nil, completedAt: done,
                 createdAt: now, updatedAt: now,
                 recurrence: recurrence, tags: tags, subtasks: subtasks, dependencies: deps)
        }

        var out: [Task] = []
        // ---- Active: Do First ----
        out.append(t("demo-finance", "Get finance sign-off", u: true, i: true, tags: ["work"]))
        out.append(t("demo-deck", "Finish the Q3 board deck", u: true, i: true, tags: ["work"],
                     subtasks: [Subtask(id: "sub1", title: "Pull revenue numbers", completed: true),
                                Subtask(id: "sub2", title: "Draft the narrative"),
                                Subtask(id: "sub3", title: "Design the key slides")],
                     deps: ["demo-finance"]))
        out.append(t("demo-investor", "Reply to the investor email", u: true, i: true, tags: ["work"]))
        // ---- Active: Schedule ----
        out.append(t("demo-vacation", "Plan the summer vacation", u: false, i: true, tags: ["family"]))
        out.append(t("demo-physical", "Book the annual physical", u: false, i: true, tags: ["health"]))
        out.append(t("demo-passport", "Renew passport", u: false, i: true, tags: ["family"]))
        // ---- Active: Delegate ----
        out.append(t("demo-newsletter", "Send the weekly newsletter", u: true, i: false,
                     tags: ["work"], recurrence: .weekly))
        out.append(t("demo-supplies", "Order office supplies", u: true, i: false, tags: ["errands"]))
        // ---- Active: Eliminate ----
        out.append(t("demo-downloads", "Sort the downloads folder", u: false, i: false, tags: ["errands"]))
        out.append(t("demo-reviews", "Browse gadget reviews", u: false, i: false))

        // ---- Completed history (drives the Dashboard trend; completedAt is preserved by create()) ----
        let done: [(String, String, Bool, Bool, [String], Int)] = [
            ("d-expense", "Submit the expense report", true, true, ["work"], 1),
            ("d-standup", "Write standup notes", true, false, ["work"], 1),
            ("d-dentist", "Call the dentist", false, true, ["health"], 2),
            ("d-pr", "Review PR #482", true, true, ["work"], 2),
            ("d-water", "Water the plants", false, false, ["home"], 3),
            ("d-card", "Pay the credit card", false, true, ["errands"], 3),
            ("d-grocery", "Grocery run", true, false, ["errands"], 4),
            ("d-login", "Fix the login bug", true, true, ["work"], 5),
            ("d-walk", "Walk the dog", true, false, ["home"], 5),
            ("d-recipe", "Try the new recipe", false, false, ["home"], 6),
            ("d-invoice", "Send the client invoice", true, true, ["work"], 7),
            ("d-1on1", "Prep the 1:1 agenda", false, true, ["work"], 8),
            ("d-laundry", "Do the laundry", true, false, ["home"], 9),
            ("d-read", "Read the design article", false, false, [], 11),
        ]
        for (id, title, u, i, tags, ago) in done {
            out.append(t(id, title, u: u, i: i, tags: tags, done: daysAgo(ago)))
        }
        return out
    }
}
```

- [ ] **Step 2: Call the seed after the store starts**

In `App/GSDApp.swift`, find the `.task { store.start() … }` block (~line 121–124). Add the seed call immediately after `store.start()`:

```swift
                .task {
                    store.start()
                    await DemoSeed.seedIfRequested(store)
```
(Leave the rest of the block — `widgetRefresher.start()` etc. — unchanged.)

- [ ] **Step 3: Regenerate the project and build for a simulator**

Run:
```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`. Fix any `Sendable`/actor-isolation diagnostics before continuing.

- [ ] **Step 4: Smoke-test the seed visually**

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GSD.app" -path "*Debug-iphonesimulator*" | head -1)
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" dev.vinny.gsd --demo-seed
sleep 4
xcrun simctl io "$UDID" screenshot /tmp/demo-matrix.png && open /tmp/demo-matrix.png
```
Expected: the Matrix shows the four quadrants populated (Do First has the board deck etc.), no onboarding screen. Tap into Dashboard manually (or re-run pointing at Dashboard) to confirm the trend chart has bars.

- [ ] **Step 5: Commit**

```bash
git add App/Support/DemoSeed.swift App/GSDApp.swift
git commit -m "feat(demo): launch-arg-gated demo seed for the marketing video"
```

---

## Task 2: Demo choreography scenes

**Files:**
- Create: `ScreenshotTests/DemoChoreography.swift`

- [ ] **Step 1: Create the choreography**

Create `ScreenshotTests/DemoChoreography.swift`:

```swift
import XCTest

/// Marketing-demo video scenes. Each is a deterministic, paced flow recorded individually by
/// `scripts/record-demo.sh` (which wraps `simctl io recordVideo`). Selected by the DEMO_SCENE env
/// var (TEST_RUNNER_-prefixed from xcodebuild). Gated by DEMO=1 so plain screenshot runs skip it.
/// NOT a correctness test.
@MainActor
final class DemoChoreography: XCTestCase {

    private var sceneName: String { ProcessInfo.processInfo.environment["DEMO_SCENE"] ?? "" }

    func testDemoScene() throws {
        guard ProcessInfo.processInfo.environment["DEMO"] == "1" else {
            throw XCTSkip("demo choreography runs only with TEST_RUNNER_DEMO=1")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed"]
        app.launch()
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 25), "tab bar never appeared")
        tabs.buttons["Matrix"].tap()
        pause(2.0)

        switch sceneName {
        case "capture":   try sceneCapture(app)
        case "matrix":    try sceneMatrix(app)
        case "complete":  try sceneComplete(app)
        case "organize":  try sceneOrganize(app)
        case "dashboard": try sceneDashboard(app, tabs)
        default: XCTFail("unknown DEMO_SCENE '\(sceneName)'")
        }
    }

    // Live shorthand parsing: title, then `!!` (priority), then `#family` (tag), each paced so
    // the quadrant pill + tag chip visibly react; submit lands it in Do First.
    private func sceneCapture(_ app: XCUIApplication) throws {
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "capture bar not found")
        field.tap(); pause(0.8)
        field.typeText("Call my wife"); pause(0.7)
        field.typeText(" !!"); pause(0.7)
        field.typeText(" #family"); pause(1.4)
        field.typeText("\n"); pause(2.0)        // Done -> lands in Do First
        field.typeText("\n"); pause(1.2)        // second Done on empty field dismisses keyboard
    }

    // Reveal all four quadrants with a slow scroll down and back.
    private func sceneMatrix(_ app: XCUIApplication) throws {
        pause(1.0)
        app.swipeUp(velocity: .slow); pause(1.4)
        app.swipeUp(velocity: .slow); pause(1.4)
        app.swipeDown(velocity: .slow); pause(1.2)
        app.swipeDown(velocity: .slow); pause(1.0)
    }

    // Swipe a seeded Do-First task to reveal Complete, tap it, dwell on the confetti.
    private func sceneComplete(_ app: XCUIApplication) throws {
        let row = app.cells.containing(.staticText, identifier: "Reply to the investor email").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "target task not on screen")
        pause(0.6)
        row.swipeRight(); pause(0.8)
        let complete = app.buttons["Complete"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 3), "Complete action not revealed")
        complete.tap(); pause(3.8)              // confetti dwell
    }

    // Open a rich seeded task; the editor sheet shows subtasks + a dependency. Scroll to reveal.
    private func sceneOrganize(_ app: XCUIApplication) throws {
        let row = app.cells.containing(.staticText, identifier: "Finish the Q3 board deck").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "rich task not on screen")
        pause(0.6)
        row.tap(); pause(2.6)                   // editor sheet presents
        app.swipeUp(velocity: .slow); pause(2.2)
        app.swipeUp(velocity: .slow); pause(2.0)   // recording ends with the editor open
    }

    private func sceneDashboard(_ app: XCUIApplication, _ tabs: XCUIElement) throws {
        tabs.buttons["Dashboard"].tap(); pause(4.5)   // charts animate in
        app.swipeUp(velocity: .slow); pause(2.5)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
```

- [ ] **Step 2: Regenerate so the new test file is in the target**

Run: `xcodegen generate`
Expected: no error. (`GSDScreenshotTests` now compiles `DemoChoreography.swift`.)

- [ ] **Step 3: Build-for-testing once**

Run:
```bash
xcodebuild build-for-testing -project GSD.xcodeproj -scheme GSDScreenshots \
  -destination "platform=iOS Simulator,id=$UDID" 2>&1 | tail -5
```
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 4: Dry-run a single scene (no recording yet)**

Run:
```bash
TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE=capture \
  xcodebuild test-without-building -project GSD.xcodeproj -scheme GSDScreenshots \
  -destination "platform=iOS Simulator,id=$UDID" \
  -only-testing:GSDScreenshotTests/DemoChoreography 2>&1 | tail -15
```
Expected: `Test Suite 'DemoChoreography' … passed`. If `textFields.firstMatch` is ambiguous or a tap misses, adjust the query (inspect with Accessibility Inspector) before recording. The other scenes reference seeded titles verbatim — if a `waitForExistence` fails, confirm the title string matches `DemoSeed` exactly.

- [ ] **Step 5: Commit**

```bash
git add ScreenshotTests/DemoChoreography.swift GSD.xcodeproj
git commit -m "test(demo): per-scene XCUITest choreography for the demo video"
```

---

## Task 3: Recording script

**Files:**
- Create: `scripts/record-demo.sh`

- [ ] **Step 1: Write the recorder**

Create `scripts/record-demo.sh`:

```bash
#!/usr/bin/env bash
# Records one clip per demo scene into build/demo/clips/. Requires a booted sim UDID.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME="GSDScreenshots"
SCENES=(capture matrix complete organize dashboard)
CLIPS="build/demo/clips"
mkdir -p "$CLIPS"

UDID="${UDID:-$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)}"
[ -n "$UDID" ] || { echo "No booted simulator. Boot one and export UDID=…"; exit 1; }
echo "Recording on $UDID"

xcodegen generate >/dev/null
xcodebuild build-for-testing -project GSD.xcodeproj -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" >/dev/null

for scene in "${SCENES[@]}"; do
  echo "=== scene: $scene ==="
  xcrun simctl io "$UDID" recordVideo --codec h264 --force "$CLIPS/$scene.mp4" &
  REC=$!
  sleep 1
  TEST_RUNNER_DEMO=1 TEST_RUNNER_DEMO_SCENE="$scene" \
    xcodebuild test-without-building -project GSD.xcodeproj -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -only-testing:GSDScreenshotTests/DemoChoreography >/dev/null || true
  sleep 1
  kill -INT "$REC"; wait "$REC" 2>/dev/null || true
  echo "   wrote $CLIPS/$scene.mp4"
done
echo "Done. Clips in $CLIPS/"
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x scripts/record-demo.sh
UDID="$UDID" ./scripts/record-demo.sh
```
Expected: five files `build/demo/clips/{capture,matrix,complete,organize,dashboard}.mp4`, each non-empty. Spot-check one: `open build/demo/clips/capture.mp4`.

- [ ] **Step 3: Verify clip dimensions**

Run: `for f in build/demo/clips/*.mp4; do echo "$f"; ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 "$f"; done`
Expected: each is portrait (e.g. `886,1920`). Record the actual width×height — `build-demo.sh` scales by height so any portrait size works.

- [ ] **Step 4: Commit**

```bash
echo "build/" >> .gitignore   # only if build/ is not already ignored
git add scripts/record-demo.sh .gitignore
git commit -m "chore(demo): scene recording script (simctl recordVideo)"
```

---

## Task 4: ffmpeg assembly

**Files:**
- Create: `scripts/build-demo.sh`

- [ ] **Step 1: Write the assembler**

Create `scripts/build-demo.sh`. Set `ICON` to the path found in Task 0 Step 3.

```bash
#!/usr/bin/env bash
# Composites scene clips onto a 16:9 cream backdrop with caption cards + music -> final mp4.
set -euo pipefail
cd "$(dirname "$0")/.."

CLIPS="build/demo/clips"; DEV="build/demo/device"; SEG="build/demo/seg"
OUT="build/demo/gsd-demo-16x9.mp4"
mkdir -p "$SEG" "$DEV"

SERIF="/System/Library/Fonts/Supplemental/Georgia.ttf"
SANS="/System/Library/Fonts/Supplemental/Arial.ttf"
ICON="${ICON:-$(find App/Assets.xcassets -iname '*.png' -path '*AppIcon*' | sort | tail -1)}"
PAPER="0xF4F1E9"; INK="0x17150F"
MUSIC="${MUSIC:-assets/demo-music.mp3}"   # optional

# seg <clip> <lead> <dur> <label> <sub> <accentHex>  -> $SEG/<name>.mp4
seg() {
  local clip="$1" lead="$2" dur="$3" label="$4" sub="$5" accent="$6"
  local name; name="$(basename "$clip" | sed 's/\.[^.]*$//')"
  local fo; fo=$(echo "$dur - 0.4" | bc)
  ffmpeg -y -ss "$lead" -t "$dur" -i "$clip" \
    -f lavfi -t "$dur" -i "color=c=$PAPER:s=1920x1080:r=30" -filter_complex "
      [0:v]scale=-2:1000,setsar=1[ph];
      [1:v]drawbox=x=236:y=44:w=474:h=1004:color=black@0.16:t=fill,boxblur=18:1[bg];
      [bg][ph]overlay=238:40[c0];
      [c0]drawbox=x=780:y=470:w=6:h=150:color=$accent:t=fill[c1];
      [c1]drawtext=fontfile='$SERIF':text='$label':x=820:y=466:fontsize=66:fontcolor=$INK[c2];
      [c2]drawtext=fontfile='$SANS':text='$sub':x=820:y=566:fontsize=34:fontcolor=$INK@0.72,
          fade=t=in:st=0:d=0.4:c=$PAPER,fade=t=out:st=$fo:d=0.4:c=$PAPER[v]
    " -map "[v]" -r 30 -c:v libx264 -pix_fmt yuv420p -an -t "$dur" "$SEG/$name.mp4"
}

# card <out> <dur> <line1> <line2>  -> full-screen cream card with icon
card() {
  local out="$1" dur="$2" l1="$3" l2="$4"; local fo; fo=$(echo "$dur - 0.5" | bc)
  ffmpeg -y -f lavfi -t "$dur" -i "color=c=$PAPER:s=1920x1080:r=30" -i "$ICON" -filter_complex "
      [1:v]scale=232:232[ic];
      [0:v][ic]overlay=(W-w)/2:300[b0];
      [b0]drawtext=fontfile='$SERIF':text='$l1':x=(w-text_w)/2:y=600:fontsize=104:fontcolor=$INK[b1];
      [b1]drawtext=fontfile='$SANS':text='$l2':x=(w-text_w)/2:y=748:fontsize=40:fontcolor=$INK@0.78,
          fade=t=in:st=0:d=0.5:c=$PAPER,fade=t=out:st=$fo:d=0.5:c=$PAPER[v]
    " -map "[v]" -r 30 -c:v libx264 -pix_fmt yuv420p -an "$out"
}

# ---- Cards ----
card "$SEG/00-title.mp4" 4 "GSD" "The calm way to get stuff done"
card "$SEG/99-cta.mp4"   6 "Private. Offline-first." "GSD on the App Store"

# ---- In-app segments (lead/dur are starting estimates; tune after viewing raw clips) ----
seg "$CLIPS/capture.mp4"   1.5 11 "Capture in plain language" "!! sets priority   #tags organize" "0xB23A2E"
seg "$CLIPS/matrix.mp4"    1.5 10 "Urgency x importance"       "Four quadrants, always in view"     "0x2C6680"
seg "$CLIPS/complete.mp4"  1.5 5  "Done feels good"            "Swipe to complete"                  "0xB23A2E"
seg "$CLIPS/organize.mp4"  1.5 9  "Built for real work"        "Subtasks, recurring, dependencies"  "0x8A6A22"
seg "$CLIPS/dashboard.mp4" 1.5 8  "See where your effort goes" "Insights, on-device"                "0x2C6680"

# ---- Device segments (only if the owner has dropped them in build/demo/device/) ----
[ -f "$DEV/widgets.mov" ] && seg "$DEV/widgets.mov" 0 8 "Always one glance away" "Home & Lock Screen widgets" "0x8A6A22"
[ -f "$DEV/siri.mov" ]    && seg "$DEV/siri.mov"    0 7 "Just ask Siri"          "Hands-free capture"          "0x6F685F"
[ -f "$DEV/share.mov" ]   && seg "$DEV/share.mov"   0 6 "Add from anywhere"      "Share into GSD from any app" "0x2C6680"

# ---- Concat in storyboard order (skip any missing optional segment) ----
order=(00-title capture matrix complete organize dashboard widgets share siri 99-cta)
: > "$SEG/list.txt"
for n in "${order[@]}"; do [ -f "$SEG/$n.mp4" ] && echo "file '$n.mp4'" >> "$SEG/list.txt"; done
ffmpeg -y -f concat -safe 0 -i "$SEG/list.txt" -r 30 -c:v libx264 -pix_fmt yuv420p "$SEG/_silent.mp4"

# ---- Music bed (optional) ----
if [ -f "$MUSIC" ]; then
  dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$SEG/_silent.mp4")
  ffmpeg -y -i "$SEG/_silent.mp4" -i "$MUSIC" \
    -filter_complex "[1:a]volume=0.32,afade=t=out:st=$(echo "$dur-2"|bc):d=2[a]" \
    -map 0:v -map "[a]" -shortest -c:v copy -c:a aac "$OUT"
else
  cp "$SEG/_silent.mp4" "$OUT"; echo "NOTE: no $MUSIC — rendered music-free."
fi
echo "Wrote $OUT"
ffprobe -v error -select_streams v:0 -show_entries stream=width,height,duration -of default=noprint_wrappers=1 "$OUT"
```

- [ ] **Step 2: Run it against the recorded clips (music-free first cut)**

```bash
chmod +x scripts/build-demo.sh
./scripts/build-demo.sh
open build/demo/gsd-demo-16x9.mp4
```
Expected: `build/demo/gsd-demo-16x9.mp4` at `width=1920 height=1080`, ~48–54s (in-app beats + 2 cards only; device beats appended later). Phone screens sit left on cream with a soft shadow; serif labels + accent rule on the right; gentle cream dips between beats.

- [ ] **Step 3: Tune trims**

Watch each beat. If a beat starts mid-launch or ends early, adjust that scene's `lead`/`dur` in `build-demo.sh` and re-run (re-running only re-encodes; it's fast). Goal: each beat opens on the action and reads cleanly.

- [ ] **Step 4: Commit**

```bash
git add scripts/build-demo.sh
git commit -m "chore(demo): ffmpeg 16:9 compositing + caption/card assembly"
```

---

## Task 5: Device shot list

**Files:**
- Create: `docs/demo-video-device-shots.md`

- [ ] **Step 1: Write the shot list**

Create `docs/demo-video-device-shots.md`:

```markdown
# GSD demo video — device shot list

Record these 2 (optionally 3) clips on your iPhone, then AirDrop them to the Mac into
`build/demo/device/` with the exact filenames below. Keep the phone vertical. Use
Control Center's screen record (red dot). ~2s of stillness at the start and end of each.

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

After dropping the files in, re-run `./scripts/build-demo.sh` to fold them in.
```

- [ ] **Step 2: Commit**

```bash
git add docs/demo-video-device-shots.md
git commit -m "docs(demo): device shot list for Siri + widget clips"
```

---

## Task 6: Final production (handoff-gated)

**Files:** none (operational)

- [ ] **Step 1: Owner records device clips** per `docs/demo-video-device-shots.md`; drop into `build/demo/device/`.
- [ ] **Step 2: Owner provides music** — place a royalty-free track at `assets/demo-music.mp3` (Pixabay/Uppbeat CC0), or leave absent for a music-free cut.
- [ ] **Step 3: Share-sheet decision** — attempt the in-app share auto-capture as a stretch (add a `share` scene to `DemoChoreography` driving Safari → share sheet → GSD); if flaky, use `share.mov` from the device list instead. Does not block the rest.
- [ ] **Step 4: Re-run assembly** — `./scripts/build-demo.sh`; confirm all beats present, length 75–85s, captions legible at 50% size (silent-autoplay check).
- [ ] **Step 5: Deliver** `build/demo/gsd-demo-16x9.mp4` to the owner.

---

## Self-Review

**Spec coverage:** Title✓(T4 card) · capture w/ live parsing✓(T2 sceneCapture) · matrix✓(sceneMatrix) · complete+confetti✓(sceneComplete) · organize: tags/subtasks/recurring/deps✓(seed + sceneOrganize) · dashboard✓(seed history + sceneDashboard) · widgets✓(T5 device) · share✓(T6 decision) · Siri✓(T5 device) · CTA/privacy✓(T4 card) · 16:9 cream composition✓(T4 seg) · captions+music✓(T4) · reproducible scripts✓(T3/T4). All spec sections map to a task.

**Placeholder scan:** No TBD/TODO. Trim `lead`/`dur` values are concrete starting numbers with an explicit tuning step (T4 S3) — normal editing, not a placeholder. `ICON`/`UDID`/`SCHEME` resolved in Task 0.

**Type/name consistency:** Seeded titles used by choreography match `DemoSeed` exactly ("Reply to the investor email", "Finish the Q3 board deck"). Launch arg `--demo-seed` consistent across `DemoSeed.launchArgument`, `DemoChoreography`, and the smoke test. Scene names `{capture,matrix,complete,organize,dashboard}` consistent across `DemoChoreography`, `record-demo.sh`, and `build-demo.sh` seg() calls. `Task.init` call uses only real params; `Subtask(id:title:completed:)` matches; `RecurrenceType.weekly` is valid.
