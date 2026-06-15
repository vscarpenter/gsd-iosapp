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

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
