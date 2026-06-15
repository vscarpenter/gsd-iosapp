# Simulated "Today's Focus" Widget Beat — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (inline) to implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Replace the real-device `widgets.MP4` with a simulator-recorded faux Home Screen scene that renders the real `TodaysFocusView`, so the marketing demo is fully reproducible from one scripted pipeline.

**Architecture:** A demo-gated `DemoHomeScreen` SwiftUI view (shown only under `--demo-home`) wraps the real widget view (compiled into the app target) in a Home-Screen tile among generic app icons. A new choreography branch records it; the build script sources the widgets beat from `build/demo/clips/` instead of `build/demo/device/`.

**Tech Stack:** SwiftUI, WidgetKit, XCUITest, XcodeGen (`project.yml`), bash + ffmpeg, `simctl`.

Spec: `docs/superpowers/specs/2026-06-15-simulated-widget-demo-scene-design.md`.

---

### Task 1: Compile the real widget view into the app target

**Files:** Modify `project.yml` (GSD target `sources`).

- [ ] **Step 1:** Add the two widget files to the GSD target `sources` (currently just `- App`):
```yaml
    sources:
      - App
      - Widgets/TodaysFocusView.swift
      - Widgets/TodaysFocusEntry.swift
```
- [ ] **Step 2:** Regenerate and confirm clean: `xcodegen generate` (no errors; rewrites `GSD.xcodeproj`).
- [ ] **Step 3:** Commit: `git add project.yml && git commit -m "build(demo): compile TodaysFocusView into the app target"`

### Task 2: Faux Home Screen view

**Files:** Create `App/Demo/DemoHomeScreen.swift`.

- [ ] **Step 1:** Create the view (full content below — uses `Surface`/`Radius`/`Color(light:dark:)` from `App/Theme/Theme.swift`, and the real `TodaysFocusView`/`TodaysFocusEntry` now in-target):

```swift
import SwiftUI
import WidgetKit
import GSDSnapshot

/// Demo-only faux iOS Home Screen for the marketing video's "Today's Focus widget" beat.
/// Renders the real `TodaysFocusView` in a Home-Screen tile among generic app icons.
/// Reachable ONLY when launched with `--demo-home` (the choreography test passes it; the app
/// never does), so this is unreachable in normal and App Store launches.
struct DemoHomeScreen: View {
    static let launchArgument = "--demo-home"

    @State private var appeared = false

    // The widget echoes the three Do-First tasks the rest of the demo already showed.
    private let entry = TodaysFocusEntry(
        date: Date(),
        snapshot: WidgetSnapshot(
            generatedAt: Date(),
            tasks: [
                WidgetTask(id: "demo-finance",  title: "Get finance sign-off", dueDate: nil),
                WidgetTask(id: "demo-deck",     title: "Finish the Q3 board deck", dueDate: nil),
                WidgetTask(id: "demo-investor", title: "Reply to the investor email", dueDate: nil),
            ],
            totalCount: 3))

    private let gridIcons: [(symbol: String, fill: Color, brand: Bool)] = [
        ("target",         Surface.surface,                     true),   // GSD's own motif (trademark-safe)
        ("envelope.fill",  Color(light: 0x4F6D7A, dark: 0x4F6D7A), false),
        ("calendar",       Color(light: 0xB23A2E, dark: 0xB23A2E), false),
        ("camera.fill",    Color(light: 0x6E6760, dark: 0x6E6760), false),
        ("map.fill",       Color(light: 0x3E7D52, dark: 0x3E7D52), false),
        ("music.note",     Color(light: 0x8A6A22, dark: 0x8A6A22), false),
        ("phone.fill",     Color(light: 0x2C6680, dark: 0x2C6680), false),
        ("gearshape.fill", Color(light: 0x4A4A4A, dark: 0x4A4A4A), false),
    ]

    var body: some View {
        ZStack {
            wallpaper.ignoresSafeArea()
            VStack(spacing: 28) {
                statusBar
                widgetTile
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 18)
                appGrid
                Spacer(minLength: 0)
                dock
            }
            .padding(.horizontal, 22)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .accessibilityIdentifier("demo-home-screen")
        .onAppear { withAnimation(.easeOut(duration: 0.6).delay(0.3)) { appeared = true } }
    }

    private var wallpaper: LinearGradient {
        LinearGradient(colors: [Color(light: 0xEFE6D2, dark: 0x17150F),
                                Color(light: 0xDDCFAF, dark: 0x100E0A)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var statusBar: some View {
        HStack {
            Text("9:41").font(.system(size: 15, weight: .semibold))
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "cellularbars")
                Image(systemName: "wifi")
                Image(systemName: "battery.100")
            }.font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(Surface.ink)
        .padding(.horizontal, 6)
    }

    private var widgetTile: some View {
        TodaysFocusView(entry: entry)
            .tint(Surface.tint)
            .padding(16)
            .frame(height: 158)
            .frame(maxWidth: .infinity)
            .background(Surface.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 18, x: 0, y: 10)
    }

    private var appGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 4), spacing: 18) {
            ForEach(gridIcons.indices, id: \.self) { i in
                appIcon(symbol: gridIcons[i].symbol, fill: gridIcons[i].fill, isBrand: gridIcons[i].brand)
            }
        }
    }

    private var dock: some View {
        HStack(spacing: 18) {
            appIcon(symbol: "message.fill", fill: Color(light: 0x3E7D52, dark: 0x3E7D52), isBrand: false)
            appIcon(symbol: "safari.fill",  fill: Color(light: 0x2C6680, dark: 0x2C6680), isBrand: false)
            appIcon(symbol: "photo.fill",   fill: Color(light: 0xB23A2E, dark: 0xB23A2E), isBrand: false)
            appIcon(symbol: "note.text",    fill: Color(light: 0x8A6A22, dark: 0x8A6A22), isBrand: false)
        }
        .padding(.vertical, 14).padding(.horizontal, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func appIcon(symbol: String, fill: Color, isBrand: Bool) -> some View {
        RoundedRectangle(cornerRadius: 15, style: .continuous)
            .fill(fill)
            .frame(width: 58, height: 58)
            .overlay(Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(isBrand ? Surface.ink : .white))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}
```

- [ ] **Step 2:** Add a write-rationale log `.claude/decisions/App_Demo_DemoHomeScreen.swift.log` (if not auto-written by a hook).

### Task 3: Route `--demo-home` to the faux Home Screen

**Files:** Modify `App/GSDApp.swift` (`body`).

- [ ] **Step 1:** Wrap the existing `ContentView()` + modifiers in an `else`; show `DemoHomeScreen()` when the arg is present:
```swift
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains(DemoHomeScreen.launchArgument) {
                DemoHomeScreen()
            } else {
                ContentView()
                    .environment(store)
                    // …all existing modifiers unchanged…
            }
        }
    }
```
- [ ] **Step 2:** `xcodegen generate` then build for iPhone + iPad sims (see Verification). Both compile clean.
- [ ] **Step 3:** Smoke: boot a sim, `xcrun simctl install` the built `.app`, `xcrun simctl launch <udid> dev.vinny.gsd --demo-home`, screenshot — confirm the widget tile shows the three tasks on the faux Home Screen.
- [ ] **Step 4:** Commit: `git add App/Demo/DemoHomeScreen.swift App/GSDApp.swift .claude/decisions && git commit -m "feat(demo): faux Home Screen widget scene rendering the real TodaysFocusView"`

### Task 4: Choreography scene

**Files:** Modify `ScreenshotTests/DemoChoreography.swift`.

- [ ] **Step 1:** Branch `widgets` before the seed/tab-bar logic in `testDemoScene`, after the DEMO guard:
```swift
        if sceneName == "widgets" { try sceneWidgets(); return }
```
- [ ] **Step 2:** Add the scene method:
```swift
    // Faux Home Screen (--demo-home): hold on the Today's Focus widget tile.
    private func sceneWidgets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-home"]
        app.launch()
        let label = app.staticTexts["Today's Focus"]
        XCTAssertTrue(label.waitForExistence(timeout: 25), "widget tile never appeared")
        pause(6.0)   // hold while the entrance settles and the recording captures it
    }
```
- [ ] **Step 3:** Commit: `git add ScreenshotTests/DemoChoreography.swift && git commit -m "test(demo): widgets choreography scene records the faux Home Screen"`

### Task 5: Pipeline — record + assemble

**Files:** Modify `scripts/record-demo.sh`, `scripts/build-demo.sh`, `docs/demo-video-device-shots.md`.

- [ ] **Step 1:** `record-demo.sh` — add `widgets` to `SCENES`:
```bash
SCENES=(capture matrix complete organize dashboard widgets)
```
- [ ] **Step 2:** `build-demo.sh` — add an in-app seg after the dashboard line (note the typographic `’`):
```bash
seg "$CLIPS/widgets.mp4"   0.5 6 "Always one glance away"     "Today’s Focus on your Home Screen"  "0x8A6A22"
```
- [ ] **Step 3:** `build-demo.sh` — delete the device widgets line (`if w=$(dev_clip widgets); then seg "$w" 1.5 6.5 …`). Leave the `siri`/`share` `dev_clip` lines as inert optional legacy.
- [ ] **Step 4:** `docs/demo-video-device-shots.md` — remove the "1. Widgets" section; update the intro to "2 optional clips (Siri, Share)" since widgets is now simulated.
- [ ] **Step 5:** Cleanup gitignored local artifacts: `rm -f build/demo/device/widgets.MP4 build/demo/device/widgets.placeholder build/demo/seg/widgets.mp4.old`.
- [ ] **Step 6:** Run the pipeline: `scripts/record-demo.sh` (regenerates `build/demo/clips/widgets.mp4`) then `FF=/usr/local/bin/ffmpeg bash scripts/build-demo.sh`. Eyeball `build/demo/gsd-demo-16x9.mp4`.
- [ ] **Step 7:** Commit: `git add scripts/record-demo.sh scripts/build-demo.sh docs/demo-video-device-shots.md && git commit -m "feat(demo): source the widgets beat from the simulated clip, retire the device recording"`

---

## Verification

```bash
xcodegen generate
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project GSD.xcodeproj -scheme GSD -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' build
cd GSDKit && swift test    # unchanged logic stays green
```
Then smoke (Task 3 Step 3) and the full pipeline (Task 5 Step 6). Final cut must show the framed Home Screen beat with no real-device footage.

## Self-Review

- **Spec coverage:** §1 DemoHomeScreen → Task 2; §2 reuse view → Task 1; §3 routing → Task 3; §4 choreography → Task 4; §5 pipeline + cleanup + docs → Task 5. All covered.
- **Placeholders:** none — every code step shows full content.
- **Type consistency:** `DemoHomeScreen.launchArgument` defined in Task 2, used in Task 3; `TodaysFocusView(entry:)` / `TodaysFocusEntry` / `WidgetSnapshot` / `WidgetTask` match the real signatures; `sceneWidgets()` defined and called in Task 4.
