import XCTest

/// App Store screenshot runner — NOT a correctness test. Drives the compact (iPhone)
/// tab UI through its main screens and writes full-resolution PNGs to SCREENSHOT_DIR.
///
/// Driven from the host via `xcodebuild test -scheme GSDScreenshots` with
/// TEST_RUNNER_-prefixed env vars (xcodebuild strips the prefix for the runner):
///   TEST_RUNNER_SCREENSHOT_DIR     output directory on the host (sim processes are unsandboxed)
///   TEST_RUNNER_SCREENSHOT_PREFIX  filename prefix, e.g. "dark-" for the dark-mode pass
///   TEST_RUNNER_SCREENSHOT_SUBSET  "1" = only Matrix + Dashboard (the dark-mode pass)
///
/// Expects a pre-seeded database and hasOnboarded=true in App-Group defaults — the
/// harness script prepares both before invoking this.
@MainActor
final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureScreenshots() throws {
        let env = ProcessInfo.processInfo.environment
        let dir = env["SCREENSHOT_DIR"] ?? "/tmp/gsd-screenshots"
        let prefix = env["SCREENSHOT_PREFIX"] ?? ""
        let subset = env["SCREENSHOT_SUBSET"] == "1"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let app = XCUIApplication()
        app.launch()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "tab bar never appeared")

        tabs.buttons["Matrix"].tap()
        settle()
        save(app, "01-matrix", dir: dir, prefix: prefix)

        tabs.buttons["Dashboard"].tap()
        settle(3)   // charts animate in
        save(app, "05-dashboard", dir: dir, prefix: prefix)

        if subset { return }

        // Task editor: tapping a row opens the edit sheet (TaskListRow.onTapGesture).
        tabs.buttons["Matrix"].tap()
        settle()
        let row = app.staticTexts["Finish investor update draft"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "seeded Q1 task not on screen")
        row.tap()
        settle()
        // The editor presents at the .medium detent; drag it to .large so the full
        // form (quadrant picker, tags, subtasks, due date) is in frame.
        let grab = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        grab.press(forDuration: 0.1, thenDragTo: top)
        settle()
        save(app, "03-editor", dir: dir, prefix: prefix)
        app.buttons["Cancel"].tap()
        settle()

        tabs.buttons["Browse"].tap()
        settle()
        save(app, "04-browse", dir: dir, prefix: prefix)

        tabs.buttons["Settings"].tap()
        settle()
        save(app, "06-settings", dir: dir, prefix: prefix)

        // Capture bar with a live parse preview — last, so the leftover draft text
        // can't pollute any other shot.
        tabs.buttons["Matrix"].tap()
        settle()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "capture bar not found")
        field.tap()
        field.typeText("Call the plumber !! #home")
        settle()
        save(app, "02-capture", dir: dir, prefix: prefix)
    }

    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func save(_ app: XCUIApplication, _ name: String, dir: String, prefix: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
    }
}
