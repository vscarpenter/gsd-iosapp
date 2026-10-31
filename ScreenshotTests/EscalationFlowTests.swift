import UIKit
import XCTest

/// Walks escalation's interactions on a SIMULATOR against the in-memory demo seed:
/// Mark urgent from the card menu and from a swipe, Undo, and the Off setting.
///
/// Simulator only, by design: `--demo-seed` runs isolated (in-memory store, signed out), but a
/// demo-seed run on the Mac has wiped a real account before, so this skips anywhere that is not
/// a simulator, and needs TEST_RUNNER_ESCALATION=1 so a plain `xcodebuild test` never runs it.
///
/// The seed's "Plan the summer vacation" (Schedule, due 7 days after the frozen clock) is the
/// escalating task: the launch argument `-escalationWindowDays 7` puts it inside the window.
@MainActor
final class EscalationFlowTests: XCTestCase {
    private let taskID = "task-card-demo-vacation"

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Escalation walk runs on a simulator only")
        #endif
        guard ProcessInfo.processInfo.environment["ESCALATION"] == "1" else {
            throw XCTSkip("Escalation walk requires TEST_RUNNER_ESCALATION=1; demo data only")
        }
    }

    /// An editor sheet left open by one walk made the next iPad launch miss its menus, so end
    /// each walk with the app closed.
    override func tearDown() async throws {
        XCUIApplication().terminate()
    }

    private func launch(windowDays: Int) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-clock", "1789146000",
                               "--demo-appearance", "light",
                               "-escalationWindowDays", String(windowDays)]
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        return app
    }

    private func card(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: taskID).firstMatch
    }

    /// After the move the card can sit outside the viewport (iPhone: the list has scrolled, and a
    /// card below or above the fold is not in the accessibility tree). Look at the top first,
    /// then work down in small steps; a default swipe flings straight past it.
    private func scrollTo(_ card: XCUIElement, in app: XCUIApplication) -> Bool {
        for _ in 0..<3 {
            if card.waitForExistence(timeout: 1) { return true }
            app.swipeDown(velocity: .slow)
        }
        for _ in 0..<8 {
            if card.waitForExistence(timeout: 1) { return true }
            app.swipeUp(velocity: .slow)
        }
        return card.exists
    }

    func testMarkUrgentFromMenuThenUndo() throws {
        let app = launch(windowDays: 7)
        let card = card(app)
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        XCTAssertTrue(card.label.contains("Escalating: due in 7 days, not marked urgent."), card.label)
        XCTAssertTrue(card.label.contains("Schedule"), card.label)

        card.buttons["More actions"].firstMatch.tap()
        let markUrgent = app.buttons["Mark urgent"].firstMatch
        XCTAssertTrue(markUrgent.waitForExistence(timeout: 5))
        markUrgent.tap()

        // The Undo toast lasts 6 seconds, and finding a card that has moved off screen can take
        // longer, so read the toast, tap Undo, and only then scroll. The swipe test checks the
        // card's new quadrant directly.
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 8), "Undo never offered")
        let message = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Marked' AND label CONTAINS 'Do First'")).firstMatch
        XCTAssertTrue(message.exists, "toast should say the task moved to Do First")

        undo.tap()
        XCTAssertTrue(scrollTo(card, in: app))
        let back = NSPredicate(format: "label CONTAINS %@", "Schedule")
        expectation(for: back, evaluatedWith: card)
        waitForExpectations(timeout: 8)
        XCTAssertTrue(card.label.contains("Escalating"), card.label)
    }

    func testMarkUrgentFromSwipe() throws {
        let app = launch(windowDays: 7)
        let card = card(app)
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        card.swipeLeft()
        let markUrgent = app.buttons["Mark urgent"].firstMatch
        XCTAssertTrue(markUrgent.waitForExistence(timeout: 5), "no Mark urgent swipe action")
        markUrgent.tap()
        XCTAssertTrue(app.buttons["Undo"].firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(scrollTo(card, in: app))
        XCTAssertTrue(card.label.contains("Do First"), card.label)
    }

    func testOffRemovesTheMarkerAndTheAction() throws {
        let app = launch(windowDays: 0)
        let card = card(app)
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        XCTAssertFalse(card.label.contains("Escalating"), card.label)
        card.buttons["More actions"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Duplicate"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Mark urgent"].firstMatch.exists)
    }

    /// On iPad the first tap on a card sometimes lands while the card is still re-rendering and opens
    /// nothing (the walk then failed before it reached the hint), so tap again.
    private func openEditor(_ card: XCUIElement, _ app: XCUIApplication) {
        let editor = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        for _ in 0..<3 {
            card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
            if editor.waitForExistence(timeout: 4) { return }
        }
        XCTFail("the editor never opened")
    }

    func testEditorShowsTheHintWhileEscalatingAndFollowsTheQuadrant() throws {
        let app = launch(windowDays: 7)
        let card = card(app)
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        openEditor(card, app)
        let hint = app.staticTexts["Moves to Do First"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "escalating task should show the hint")

        // Moving the draft to Do First (urgent) stops it escalating, so the hint goes.
        app.buttons["Do First"].firstMatch.tap()
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5), "an urgent draft must not show the hint")
    }

    func testEditorHasNoHintWhenOff() throws {
        let app = launch(windowDays: 0)
        let card = card(app)
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        openEditor(card, app)
        XCTAssertFalse(app.staticTexts["Moves to Do First"].firstMatch.waitForExistence(timeout: 2))
    }
}
