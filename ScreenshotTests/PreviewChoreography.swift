import UIKit
import XCTest

/// App Preview video choreography — a single scripted ~20-second flow, recorded from the
/// host with `simctl io recordVideo` while this runs. NOT a correctness test.
///
/// Story: capture a task with live shorthand parsing → it lands in Do First →
/// complete it with a swipe (confetti) → end on the Dashboard analytics.
///
/// Gated behind TEST_RUNNER_PREVIEW=1 so plain `GSDScreenshots` scheme runs (the
/// screenshot passes) skip it.
@MainActor
final class PreviewChoreography: XCTestCase {

    func testPreviewFlow() throws {
        guard ProcessInfo.processInfo.environment["PREVIEW"] == "1" else {
            throw XCTSkip("preview choreography runs only with TEST_RUNNER_PREVIEW=1")
        }
        let app = XCUIApplication()
        app.launch()

        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 15), "tab bar never appeared")
        tabs.buttons["Matrix"].tap()
        pause(2.5)

        // Capture with live parsing: title, then !!, then #family — paced so the
        // quadrant pill and tag chip visibly react to each token.
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "capture bar not found")
        field.tap()
        pause(0.8)
        field.typeText("Call my wife")
        pause(0.7)
        field.typeText(" !!")
        pause(0.7)
        field.typeText(" #family")
        pause(1.4)
        field.typeText("\n")   // keyboard Done -> CaptureBar.onSubmit -> lands in Do First
        pause(1.2)

        // CaptureBar re-focuses the field after a successful add. A second Done on the
        // now-EMPTY field falls through submit()'s title guard without re-focusing, so
        // the system dismisses the keyboard — the only deterministic dismissal here.
        field.typeText("\n")
        pause(1.2)

        // Complete the new task: XCUITest's swipeRight is too short for a full-swipe
        // execute — it reveals the leading Complete action, which we then tap. Reads
        // naturally on video (gesture, then a deliberate confirm) and fires the confetti.
        let row = app.cells.containing(.staticText, identifier: "Call my wife").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "captured task not on screen")
        row.swipeRight()
        pause(0.8)
        let complete = app.buttons["Complete"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 3), "Complete swipe action not revealed")
        complete.tap()
        pause(3.5)   // confetti dwell

        tabs.buttons["Dashboard"].tap()
        pause(4.5)
    }

    private func pause(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }
}
