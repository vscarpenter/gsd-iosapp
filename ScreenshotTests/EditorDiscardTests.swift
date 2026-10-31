import UIKit
import XCTest

/// Opt-in smoke for the editor's "Discard changes?" prompt (B-18). Simulator only, demo data
/// only (`TEST_RUNNER_EDITOR_DISCARD=1`): `--demo-seed` runs isolated, but a seed run on the
/// Mac has wiped a real account before, so this skips anywhere that is not a simulator.
@MainActor
final class EditorDiscardTests: XCTestCase {
    func testCancelAsksOnlyWhenTheDraftChanged() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Editor discard walk runs on a simulator only")
        #endif
        guard ProcessInfo.processInfo.environment["EDITOR_DISCARD"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_EDITOR_DISCARD=1 on a simulator; demo data only")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-clock", "1789146000", "--demo-appearance", "light"]
        app.launch()
        let card = element(app, "task-card-demo-investor")
        XCTAssertTrue(card.waitForExistence(timeout: 35))

        // Untouched: Cancel closes with no prompt.
        openEditor(card, app)
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(element(app, "task-editor").waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Discard changes?"].exists)

        // Edited: Cancel asks. Keep Editing stays; Discard Changes closes.
        openEditor(card, app)
        let title = app.textFields["Title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(" edited")
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(app.alerts["Discard changes?"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(element(app, "task-editor").exists, "Keep Editing must leave the editor open")

        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(element(app, "task-editor").waitForNonExistence(timeout: 5))
        XCTAssertFalse(card.label.contains("edited"), "a discarded edit must not reach the task")
    }

    private func openEditor(_ card: XCUIElement, _ app: XCUIApplication) {
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        XCTAssertTrue(element(app, "task-editor").waitForExistence(timeout: 5))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
