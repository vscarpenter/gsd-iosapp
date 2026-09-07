import UIKit
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
        // The widget beat is a faux Home Screen, not the app's tabbed UI — handle it before the
        // shared --demo-seed launch + tab-bar wait below.
        if sceneName == "widgets" { try sceneWidgets(); return }
        // The continuous per-device reels (hero clip + App-Store previews) own their full launch
        // (fixed clock + forced appearance) and platform-specific flow — see runReel().
        if sceneName.hasPrefix("reel-") { try runReel(); return }
        // The product-video clips (one per beat) own their launch too, plus a host-recorder handshake.
        if sceneName.hasPrefix("video-") { try runVideoScene(); return }
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

    // Faux Home Screen (--demo-home): hold on the Today's Focus widget tile while it settles.
    private func sceneWidgets() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-home"]
        app.launch()
        let label = app.staticTexts["Today's Focus"]
        XCTAssertTrue(label.waitForExistence(timeout: 25), "widget tile never appeared")
        pause(6.0)   // hold while the entrance settles and the recording captures it
    }

    // MARK: - Continuous per-device reels

    /// Fixed clock for the reels: 2025-06-20 12:00 UTC (Friday midday). Seeded due dates are
    /// offsets from this, so "Overdue / Due today / in 2 days" render identically on every take.
    static let demoEpoch = 1_750_420_800

    /// One continuous take per device — the marketing hero clip + App-Store previews. Each begins
    /// and ends on the populated matrix so the muted web loop is seamless. Selected by DEMO_SCENE.
    private func runReel() throws {
        let app = launchReelApp()
        switch sceneName {
        case "reel-iphone": try reelIPhone(app)
        case "reel-ipad":   try reelIPad(app)
        case "reel-mac":    try reelMac(app)
        default: XCTFail("unknown reel scene '\(sceneName)'")
        }
    }

    /// Launches the seeded app with the frozen clock and forced appearance. DEMO_APPEARANCE
    /// (light|dark) is supplied by `scripts/record-demos.sh`; defaults to light.
    private func launchReelApp() -> XCUIApplication {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["DEMO_APPEARANCE"] ?? "light"
        app.launchArguments = ["--demo-seed",
                               "--demo-clock", "\(Self.demoEpoch)",
                               "--demo-appearance", appearance]
        app.launch()
        return app
    }

    // iPhone (portrait): capture → complete → scroll the four sections → open/close a task,
    // ending back at the top of the matrix.
    private func reelIPhone(_ app: XCUIApplication) throws {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 25), "tab bar never appeared")
        tabs.buttons["Matrix"].tap(); pause(1.2)

        captureBeat(app)
        dismissKeyboard(app)
        completeBeat(app)

        // Scroll through all four quadrant sections and back to the top (clean loop point).
        pause(0.6)
        app.swipeUp(velocity: .slow); pause(1.2)
        app.swipeUp(velocity: .slow); pause(1.2)
        app.swipeDown(velocity: .slow); pause(1.1)
        app.swipeDown(velocity: .slow); pause(1.0)

        // Open a rich task (subtasks + dependency), dwell, then close.
        let deck = card(app, "demo-deck")
        if deck.waitForExistence(timeout: 5) {
            deck.tap(); pause(0.5)
            if element(app, "task-editor").waitForExistence(timeout: 5) { pause(1.8) }
            app.buttons["editor-cancel"].firstMatch.tap(); pause(1.2)
        }
        pause(1.0)   // settle on the populated matrix
    }

    // iPad: capture → complete → DRAG a card across a quadrant boundary to reclassify. Recorded
    // PORTRAIT — `simctl recordVideo` captures the portrait framebuffer regardless of in-app
    // rotation (an XCUIDevice landscape flip records sideways), and portrait 13" (2064×2752) is a
    // valid App-Store size that still shows the true 2×2 board in the split-view detail.
    private func reelIPad(_ app: XCUIApplication) throws {
        XCUIDevice.shared.orientation = .portrait   // reset any prior rotation; record upright portrait
        XCTAssertTrue(app.textFields["capture-field"].waitForExistence(timeout: 25), "matrix never appeared")
        pause(1.2)

        captureBeat(app)
        dismissKeyboard(app)
        completeBeat(app)

        // The iPad-only gesture worth showing: drag a Do-First card sideways across the boundary
        // into Schedule. Both quadrants sit in the always-visible top row, so source/target are
        // hittable; the long-press lift starts `.draggable` and the drop hits Schedule's
        // `.dropDestination`, reclassifying the task.
        let source = card(app, "demo-deck")
        let target = card(app, "demo-passport")
        if source.waitForExistence(timeout: 5), target.waitForExistence(timeout: 5) {
            pause(0.6)
            source.press(forDuration: 1.0, thenDragTo: target); pause(2.0)
        }
        pause(1.2)   // settle on the 2×2 board
    }

    // Mac: capture, then the keyboard flow — ⌘K command palette → run a smart view → ⌘1 back.
    private func reelMac(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.textFields["capture-field"].waitForExistence(timeout: 25), "matrix never appeared")
        pause(1.0)

        captureBeat(app)
        dismissKeyboard(app)   // no-op on Mac (no software keyboard)

        // ⌘K opens the palette; type a smart-view name and run it, then ⌘1 returns to the matrix.
        app.typeKey("k", modifierFlags: .command); pause(1.3)
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap(); field.typeText("Today"); pause(1.2)
            let row = element(app, "palette-row-Today's Focus")
            if row.waitForExistence(timeout: 3) { row.tap() }
            pause(2.4)   // dwell on the smart-view results
        }
        app.typeKey("1", modifierFlags: .command); pause(1.8)   // back to Do First on the matrix
    }

    // MARK: Shared reel beats

    /// Live shorthand parse: title, then `!!` (recolors the quadrant chip to Do First), then
    /// `#work` (tag chip appears); submit lands the card in Do First. Each step is paced to read.
    private func captureBeat(_ app: XCUIApplication) {
        let field = app.textFields["capture-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "capture field not found")
        field.tap(); pause(0.9)
        field.typeText("Email the architect"); pause(0.9)
        field.typeText(" !!"); pause(1.0)
        field.typeText(" #work"); pause(1.1)
        field.typeText("\n"); pause(1.6)
    }

    /// Swipe a seeded Do-First card to complete it: green fill + confetti. The swipe action button
    /// is reached by its (localized) "Complete" label — SwiftUI doesn't expose an identifier on
    /// `.swipeActions` / hand-rolled reveal buttons reliably.
    private func completeBeat(_ app: XCUIApplication) {
        let c = card(app, "demo-investor")
        XCTAssertTrue(c.waitForExistence(timeout: 10), "investor card not found")
        pause(0.6)
        c.swipeRight(); pause(0.8)
        let complete = app.buttons["Complete"].firstMatch
        if complete.waitForExistence(timeout: 3) { complete.tap() }
        pause(3.6)   // green fill + confetti dwell
    }

    /// Resigns the keyboard so the next beat reads cleanly. No-op when no software keyboard is up.
    /// iPad shows a dedicated dismiss key; iPhone has none, so tap the nav-bar title (outside the
    /// field) to resign it without opening anything.
    private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.keyboards.buttons["Hide keyboard"]
        // Tap the key by coordinate: a plain tap() first tries to scroll it "into view", which fails
        // in landscape because the key's frame is reported in portrait coordinates.
        if hide.exists { hide.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.07)).tap() }
        pause(0.6)
    }

    // MARK: - Product-video clips (docs/superpowers/specs/2026-09-07-product-video-design.md)

    /// Frozen clock for the product video. scripts/capture-video-clips.sh passes VIDEO_EPOCH as noon
    /// local on the recording day, so the app's "today" matches the date the iPad status bar shows
    /// (simctl can pin the time but not the date). Without the script it falls back to a fixed
    /// Friday, 2026-09-11 17:00 UTC.
    static var videoEpoch: Int {
        Int(ProcessInfo.processInfo.environment["VIDEO_EPOCH"] ?? "") ?? 1_789_146_000
    }

    /// One clip per beat of the 45-second product video. Each scene launches seeded with the frozen
    /// clock and light appearance, waits for the seeded matrix, then hands off to the host recorder:
    /// touch VIDEO_READY (the recorder starts), hold so the clip opens on a settled screen, run the
    /// beat, hold again, touch VIDEO_DONE (the recorder stops on the closing hold). Both env vars are
    /// optional, so the scenes also run without a recorder attached.
    private func runVideoScene() throws {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        if isPad {
            // The split view (sidebar + 2×2 board) reads best wide. simctl records the portrait
            // framebuffer, so scripts/capture-video-clips.sh rotates the clip back upright.
            XCUIDevice.shared.orientation = .landscapeLeft
            pause(1.5)   // launching sooner trips a transient accessibility error on the springboard
        }
        let app = XCUIApplication()
        if sceneName == "video-widget" {
            app.launchArguments = ["--demo-home"]
            app.launch()
            XCTAssertTrue(app.staticTexts["Today's Focus"].waitForExistence(timeout: 25), "widget tile never appeared")
            pause(1.2)             // let the tile's entrance settle before the recorder starts
            signal("VIDEO_READY")
            pause(8.0)             // opening hold + dwell + closing hold
            signal("VIDEO_DONE")
            pause(1.0)             // keep the app up while the recorder stops, so no springboard frame lands in the clip
            return
        }
        app.launchArguments = ["--demo-seed",
                               "--demo-clock", "\(Self.videoEpoch)",
                               "--demo-appearance", "light"]
        app.launch()
        if !isPad {
            let tabs = app.tabBars.firstMatch
            XCTAssertTrue(tabs.waitForExistence(timeout: 25), "tab bar never appeared")
            tabs.buttons["Matrix"].tap()
        }
        XCTAssertTrue(app.textFields["capture-field"].waitForExistence(timeout: 25), "matrix never appeared")
        // The seed wipes and reloads the store after launch; wait for a seeded card so the clip never
        // opens on the first-frame skeleton.
        XCTAssertTrue(card(app, "demo-investor").waitForExistence(timeout: 20), "seeded cards never appeared")
        pause(1.0)
        signal("VIDEO_READY")
        pause(2.0)                 // recorder spin-up + the opening hold

        switch sceneName {
        case "video-matrix":    videoMatrix(app, isPad: isPad)
        case "video-capture":   videoCapture(app)
        case "video-complete":  completeBeat(app)
        case "video-dashboard": videoDashboard(app, isPad: isPad)
        case "video-drag":      videoDrag(app)
        default: XCTFail("unknown video scene '\(sceneName)'")
        }

        pause(1.2)                 // closing hold
        signal("VIDEO_DONE")
        pause(1.0)                 // keep the app up while the recorder stops (see the widget scene)
    }

    // Problem beat. iPhone: two slow scrolls reveal the four quadrant sections (a slow XCUITest swipe
    // takes about 1.5 s on its own, so two keep the clip inside the beat). iPad: the whole board is
    // already on screen, so hold.
    private func videoMatrix(_ app: XCUIApplication, isPad: Bool) {
        if isPad { pause(4.5); return }
        app.swipeUp(velocity: .slow); pause(1.0)
        app.swipeUp(velocity: .slow); pause(1.0)
    }

    // Capture beat, same copy as the shipped App Store screenshot: the title, then `!!` recolors the
    // quadrant chip to Do First, then `#home` adds the tag chip; Return lands the card in Do First.
    private func videoCapture(_ app: XCUIApplication) {
        let field = app.textFields["capture-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "capture field not found")
        field.tap(); pause(0.8)
        field.typeText("Call the plumber"); pause(0.8)
        field.typeText(" !!"); pause(0.9)
        field.typeText(" #home"); pause(1.0)
        field.typeText("\n"); pause(1.4)
        dismissKeyboard(app)
    }

    // Dashboard beat: open it, let the charts animate in, then scroll to the quadrant rings.
    private func videoDashboard(_ app: XCUIApplication, isPad: Bool) {
        if isPad { app.staticTexts["Dashboard"].firstMatch.tap() }
        else { app.tabBars.firstMatch.buttons["Dashboard"].tap() }
        pause(2.4)
        app.swipeUp(velocity: .slow); pause(1.6)
    }

    // iPad-only reclassify: lift a Do-First card and drop it across the boundary into Schedule.
    private func videoDrag(_ app: XCUIApplication) {
        let source = card(app, "demo-deck")
        let target = card(app, "demo-passport")
        guard source.waitForExistence(timeout: 5), target.waitForExistence(timeout: 5) else {
            XCTFail("drag cards not on screen"); return
        }
        source.press(forDuration: 1.0, thenDragTo: target); pause(2.2)
    }

    /// Touches the file named by an env var (TEST_RUNNER_-prefixed from xcodebuild). Simulator
    /// processes share the host filesystem, so the capture script polls the same path.
    private func signal(_ key: String) {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    // MARK: Element helpers

    /// Seeded task titles, for the label-based fallback below.
    static let titles: [String: String] = [
        "demo-investor": "Reply to the investor email",
        "demo-deck": "Finish the Q3 board deck",
        "demo-supplies": "Order office supplies",
        "demo-finance": "Get finance sign-off",
        "demo-passport": "Renew passport",
    ]

    /// The card element for a seeded task id. The `task-card-<id>` identifier surfaces inside the
    /// iPhone `List`, but the iPad `SwipeRevealRow` (custom drag/context-menu wrapping) hides it —
    /// so fall back to matching the accessibility label, which begins with the task title on both.
    private func card(_ app: XCUIApplication, _ taskID: String) -> XCUIElement {
        let byID = element(app, "task-card-\(taskID)")
        if byID.exists { return byID }
        let title = Self.titles[taskID] ?? taskID
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Resolves an accessibility identifier regardless of the element's reported type.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
