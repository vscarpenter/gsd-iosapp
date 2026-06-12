import UIKit
import XCTest

/// App Store screenshot runner — NOT a correctness test. Drives the live app through its
/// main screens and writes full-resolution PNGs to SCREENSHOT_DIR. Branches on idiom:
/// iPhone walks the compact TabView; iPad rotates to landscape and walks the
/// NavigationSplitView sidebar.
///
/// Driven from the host via `xcodebuild test -scheme GSDScreenshots` with
/// TEST_RUNNER_-prefixed env vars (xcodebuild strips the prefix for the runner):
///   TEST_RUNNER_SCREENSHOT_DIR     output directory on the host (sim processes are unsandboxed)
///   TEST_RUNNER_SCREENSHOT_PREFIX  filename prefix, e.g. "dark-" / "ipad-dark-"
///   TEST_RUNNER_SCREENSHOT_SUBSET  "1" = only Matrix + Dashboard (the dark-mode pass)
///
/// Expects a pre-seeded database and hasOnboarded=true in App-Group defaults — the
/// harness script prepares both before invoking this.
@MainActor
final class ScreenshotTests: XCTestCase {

    private var dir = "/tmp/gsd-screenshots"
    private var prefix = ""
    private var subset = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        dir = env["SCREENSHOT_DIR"] ?? dir
        prefix = env["SCREENSHOT_PREFIX"] ?? ""
        subset = env["SCREENSHOT_SUBSET"] == "1"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }

    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        if UIDevice.current.userInterfaceIdiom == .pad {
            // Landscape shows sidebar + detail together — the iPad layout's best angle.
            XCUIDevice.shared.orientation = .landscapeLeft
            settle()
            app.launch()
            try capturePad(app)
        } else {
            app.launch()
            try capturePhone(app)
        }
    }

    // MARK: - iPhone (compact TabView)

    private func capturePhone(_ app: XCUIApplication) throws {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "tab bar never appeared")

        tabs.buttons["Matrix"].tap()
        settle()
        save(app, "01-matrix")

        tabs.buttons["Dashboard"].tap()
        settle(3)   // charts animate in
        save(app, "05-dashboard")

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
        save(app, "03-editor")
        app.buttons["Cancel"].tap()
        settle()

        tabs.buttons["Browse"].tap()
        settle()
        save(app, "04-browse")

        tabs.buttons["Settings"].tap()
        settle()
        save(app, "06-settings")

        // Capture bar with a live parse preview — last, so the leftover draft text
        // can't pollute any other shot.
        tabs.buttons["Matrix"].tap()
        settle()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "capture bar not found")
        field.tap()
        field.typeText("Call the plumber !! #home")
        settle()
        save(app, "02-capture")
    }

    // MARK: - iPad (NavigationSplitView sidebar)

    private func capturePad(_ app: XCUIApplication) throws {
        // Sidebar rows are List-selection rows; their labels surface as static texts.
        let matrixRow = app.staticTexts["Matrix"].firstMatch
        XCTAssertTrue(matrixRow.waitForExistence(timeout: 15), "sidebar never appeared")

        matrixRow.tap()
        settle()
        save(app, "01-matrix")

        app.staticTexts["Dashboard"].firstMatch.tap()
        settle(3)   // charts animate in
        save(app, "04-dashboard")

        if subset { return }

        // Editor: a task card in the matrix grid opens the edit sheet (form sheet,
        // centered and full-height on iPad — no detent drag needed).
        matrixRow.tap()
        settle()
        let card = app.staticTexts["Finish investor update draft"]
        XCTAssertTrue(card.waitForExistence(timeout: 5), "seeded Q1 task not on screen")
        card.tap()
        settle()
        save(app, "02-editor")
        app.buttons["Cancel"].tap()
        settle()

        // A built-in smart view in the detail column.
        app.staticTexts["This Week"].firstMatch.tap()
        settle()
        save(app, "03-smartview")

        app.staticTexts["Settings"].firstMatch.tap()
        settle()
        save(app, "05-settings")
    }

    // MARK: - Helpers

    private func settle(_ seconds: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
    }
}
