import UIKit
import XCTest

@MainActor
final class SavedFlowTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SAVED"] == "1" else {
            throw XCTSkip("Saved walk requires TEST_RUNNER_SAVED=1; demo data only")
        }
    }

    func testSaveNotesSearchAndReturn() throws {
        let app = XCUIApplication()
        let appearance = ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] ?? "light"
        app.launchArguments = ["--demo-seed", "--demo-clock", "1789146000", "--demo-appearance", appearance]
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        app.launch()
        let card = element(app, "task-card-demo-investor")
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        card.buttons["More actions"].firstMatch.tap()
        app.buttons["Move to Saved"].firstMatch.tap()
        XCTAssertTrue(card.waitForNonExistence(timeout: 8))
        openSaved(app)
        try capture(app, "opened")
        let notesButton = element(app, "saved-notes-demo-investor")
        XCTAssertTrue(notesButton.waitForExistence(timeout: 8))
        notesButton.tap()
        let notes = app.textViews["saved-notes-field"]
        XCTAssertTrue(notes.waitForExistence(timeout: 5))
        notes.tap()
        notes.typeText("\nRead when the project restarts. https://example.com/reading")
        try capture(app, "notes")
        app.buttons["saved-editor-save"].tap()
        XCTAssertTrue(element(app, "saved-editor").waitForNonExistence(timeout: 8))
        XCTAssertTrue(notesButton.label.contains("Read when the project restarts"))
        try capture(app, "library")

        let search = app.searchFields["Search Saved"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("restarts")
        XCTAssertTrue(notesButton.waitForExistence(timeout: 5))
        search.typeText("zzznomatch")
        XCTAssertTrue(app.staticTexts["No saved items found"].waitForExistence(timeout: 5))
        let clear = search.buttons["Clear text"].firstMatch
        if clear.exists { clear.tap() }
        if app.buttons["Cancel"].firstMatch.exists { app.buttons["Cancel"].firstMatch.tap() }

        element(app, "saved-actions-demo-investor").tap()
        app.buttons["Return to matrix"].firstMatch.tap()
        XCTAssertTrue(element(app, "saved-return-quadrant").waitForExistence(timeout: 5))
        try capture(app, "return")
        app.buttons["saved-editor-save"].tap()
        XCTAssertTrue(notesButton.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Nothing saved yet"].waitForExistence(timeout: 5))
        try capture(app, "returned")
        if app.tabBars.firstMatch.exists {
            let bar = app.tabBars.firstMatch
            if !bar.buttons["Matrix"].isHittable { bar.buttons["Browse"].tap() }
            bar.buttons["Matrix"].tap()
        } else { navigationItem(app, "Matrix").tap() }
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()
        XCTAssertTrue(element(app, "task-editor").waitForExistence(timeout: 5))
        let details = app.buttons["Show all details"]
        if details.exists { details.tap() }
        let description = element(app, "editor-description")
        XCTAssertTrue(description.waitForExistence(timeout: 5))
        XCTAssertTrue((description.value as? String ?? "").contains("Read when the project restarts"))
    }

    func testSaveAndDeleteUndo() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-appearance",
                               ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] ?? "light"]
        app.launch()
        let card = element(app, "task-card-demo-investor")
        XCTAssertTrue(card.waitForExistence(timeout: 35))
        card.buttons["More actions"].firstMatch.tap()
        app.buttons["Move to Saved"].firstMatch.tap()
        let undo = app.buttons["Undo"].firstMatch
        XCTAssertTrue(undo.waitForExistence(timeout: 3)); undo.tap()
        XCTAssertTrue(card.waitForExistence(timeout: 8))
        card.buttons["More actions"].firstMatch.tap()
        app.buttons["Move to Saved"].firstMatch.tap()
        openSaved(app)
        let notes = element(app, "saved-notes-demo-investor")
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
        element(app, "saved-actions-demo-investor").tap()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 3)); undo.tap()
        XCTAssertTrue(notes.waitForExistence(timeout: 8))
    }

    private func openSaved(_ app: XCUIApplication) {
        if app.buttons["Browse"].firstMatch.exists { app.buttons["Browse"].firstMatch.tap() }
        let link = element(app, "browse-saved")
        if link.exists { link.tap() } else { navigationItem(app, "Saved").tap() }
    }

    private func navigationItem(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) throws {
        #if targetEnvironment(macCatalyst)
        let screenshot = app.windows.firstMatch.screenshot()
        #else
        let screenshot = XCUIScreen.main.screenshot()
        #endif
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "saved-\(name)"; attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let prefix = ProcessInfo.processInfo.environment["SCREENSHOT_PREFIX"] ?? ""
            try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(prefix)saved-\(name).png"))
        }
    }
}
