import UIKit
import XCTest

/// Opt-in smoke for the editor's due time of day (D-1): the All day toggle and the time picker.
/// Runs on a disposable simulator with demo data only (`TEST_RUNNER_DUE_TIME=1`).
@MainActor
final class DueTimeEditorTests: XCTestCase {
    func testAllDayToggleRevealsTheTimePicker() throws {
        guard ProcessInfo.processInfo.environment["DUE_TIME"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_DUE_TIME=1 on a disposable simulator; demo data only")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-clock", "1789146000", "--demo-appearance", "light"]
        app.launch()
        let card = element(app, "task-card-demo-investor")
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        XCTAssertTrue(element(app, "task-editor").waitForExistence(timeout: 5))
        let details = app.buttons["Show all details"]
        if details.exists { details.tap() }

        let hasDue = app.switches["Has due date"]
        scrollTo(hasDue, in: app)
        if hasDue.value as? String == "0" { hasDue.switches.firstMatch.tap() }

        let allDay = app.switches["All day"]
        scrollTo(allDay, in: app)
        XCTAssertTrue(allDay.exists, "All day toggle missing")
        if allDay.value as? String == "0" { allDay.switches.firstMatch.tap() }
        XCTAssertEqual(allDay.value as? String, "1")
        XCTAssertFalse(timePicker(app).exists, "time picker should be hidden while All day is on")

        allDay.switches.firstMatch.tap()
        XCTAssertTrue(timePicker(app).waitForExistence(timeout: 3), "time picker should appear when All day is off")
        attach(app, "due-time-picker")
    }

    private func timePicker(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Due time'")).firstMatch
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !element.isHittable && tries < 8 { app.swipeUp(); tries += 1 }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let dir = ProcessInfo.processInfo.environment["DUE_SHOT_DIR"] {
            try? app.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
