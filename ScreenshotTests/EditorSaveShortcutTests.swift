import XCTest

/// Opt-in walk for the task editor's ⌘S (issue #39), gated on `TEST_RUNNER_EDITOR_SAVE_SHORTCUT=1`.
/// Runs on simulators and Mac Catalyst. Any `--demo-` launch gets an empty in-memory store and no
/// session (`HarnessLaunch.isIsolated`), so it is safe on a signed-in Mac and needs no fixtures.
/// Tasks reopen through the ⌘K palette because card taps don't register in Mac UI tests.
@MainActor
final class EditorSaveShortcutTests: XCTestCase {
    func testSavesATagTypedButNotAdded() throws {
        let app = try launch()
        startNewTask(app, title: "Water the ferns")
        let tagField = app.textFields["Add tag"]
        reveal(tagField, in: app)
        tagField.tap()
        tagField.typeText("garden")

        pressSave(app)

        XCTAssertTrue(editor(app).waitForNonExistence(timeout: 5), "⌘S must close the editor")
        XCTAssertEqual(cards(app, title: "Water the ferns").count, 1, "one save, one task")
        reopen(app, title: "Water the ferns")
        XCTAssertTrue(app.buttons["Remove tag garden"].waitForExistence(timeout: 5),
                      "the unadded tag must be saved with the task")
    }

    func testSavesFromTheNotesField() throws {
        let app = try launch()
        startNewTask(app, title: "Call the plumber")
        let notes = element(app, "editor-description")
        reveal(notes, in: app)
        notes.tap()
        notes.typeText("Ask about the valve")

        pressSave(app)

        XCTAssertTrue(editor(app).waitForNonExistence(timeout: 5), "⌘S must reach past the multi-line field")
        reopen(app, title: "Call the plumber")
        let saved = element(app, "editor-description")
        reveal(saved, in: app)
        XCTAssertEqual(saved.value as? String, "Ask about the valve")
    }

    func testSavesEditsToAnExistingTask() throws {
        let app = try launch()
        startNewTask(app, title: "Book the dentist")
        app.buttons["editor-save"].tap()
        XCTAssertTrue(editor(app).waitForNonExistence(timeout: 5))
        reopen(app, title: "Book the dentist")
        let tagField = app.textFields["Add tag"]
        reveal(tagField, in: app)
        tagField.tap()
        tagField.typeText("health")

        pressSave(app)

        XCTAssertTrue(editor(app).waitForNonExistence(timeout: 5), "⌘S must close an existing task's editor")
        XCTAssertEqual(cards(app, title: "Book the dentist").count, 1)
        reopen(app, title: "Book the dentist")
        XCTAssertTrue(app.buttons["Remove tag health"].waitForExistence(timeout: 5))
    }

    func testDoesNothingWithoutATitle() throws {
        let app = try launch()
        openNewEditor(app)

        pressSave(app)

        XCTAssertFalse(editor(app).waitForNonExistence(timeout: 2), "an untitled task must not save")
    }

    func testAFailedSaveKeepsTheEditorOpenAndSaveAvailable() throws {
        let app = try launch()
        startNewTask(app, title: String(repeating: "x", count: 81))

        pressSave(app)

        XCTAssertFalse(editor(app).waitForNonExistence(timeout: 2), "a rejected title must keep the editor open")
        XCTAssertTrue(app.buttons["editor-save"].isEnabled, "a failed save must not lock Save")
    }

    /// Opens the editor by tap, so ⌘S is the first shortcut of the session: the reporter's flow.
    /// Mac only, because the simulators drop the first ⌘ key after a launch, whichever shortcut it
    /// is (⌘N and ⌘K too), and the second press works.
    func testSavesOnTheFirstPressAfterOpeningByTap() throws {
        #if !targetEnvironment(macCatalyst)
        throw XCTSkip("The simulator drops the first ⌘ key of a launch")
        #else
        let app = try launch()
        let add = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Add to Do First'")).firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 5), "the empty quadrant's button must open the editor")
        let field = app.textFields["Title"]
        field.tap()
        field.typeText("Sort the mail")

        pressSave(app)

        XCTAssertTrue(editor(app).waitForNonExistence(timeout: 5), "the first ⌘S must close the editor")
        #endif
    }

    func testDoesNothingBehindTheDiscardAlert() throws {
        let app = try launch()
        startNewTask(app, title: "Renew the passport")
        app.buttons["editor-cancel"].tap()
        let alert = app.alerts["Discard changes?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))

        pressSave(app)

        XCTAssertFalse(alert.waitForNonExistence(timeout: 2), "⌘S must leave the alert up")
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(editor(app).waitForNonExistence(timeout: 5))
        XCTAssertEqual(cards(app, title: "Renew the passport").count, 0, "a discarded draft must not save")
    }

    func testDoesNothingBehindTheDependencyPicker() throws {
        let app = try launch()
        startNewTask(app, title: "File the receipts")
        let addDependency = app.buttons["Add dependency…"]
        reveal(addDependency, in: app)
        addDependency.tap()
        let picker = app.navigationBars["Add Dependency"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))

        pressSave(app)

        XCTAssertFalse(picker.waitForNonExistence(timeout: 2), "⌘S must leave the picker up")
        picker.buttons["Cancel"].tap()
        XCTAssertTrue(picker.waitForNonExistence(timeout: 5))
        XCTAssertTrue(editor(app).exists, "the editor under the picker must stay open")
        XCTAssertEqual(cards(app, title: "File the receipts").count, 0, "nothing saved behind the picker")
    }

    // MARK: Helpers

    private func launch() throws -> XCUIApplication {
        #if !targetEnvironment(simulator) && !targetEnvironment(macCatalyst)
        throw XCTSkip("Editor save shortcut walk runs on a simulator or Mac Catalyst")
        #else
        guard ProcessInfo.processInfo.environment["EDITOR_SAVE_SHORTCUT"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_EDITOR_SAVE_SHORTCUT=1")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo-clock", "1789146000", "--demo-appearance", "light"]
        app.launch()
        return app
        #endif
    }

    private func pressSave(_ app: XCUIApplication) {
        app.typeKey("s", modifierFlags: .command)
    }

    /// Retries because the simulators usually drop the first ⌘ key after a launch. ⌘N is only the
    /// way in here. `pressSave` stays a single press, since ⌘S is what's under test.
    private func openNewEditor(_ app: XCUIApplication) {
        for _ in 1...4 {
            app.typeKey("n", modifierFlags: .command)
            if editor(app).waitForExistence(timeout: 3) { return }
        }
        XCTFail("⌘N must open the editor")
    }

    private func startNewTask(_ app: XCUIApplication, title: String) {
        openNewEditor(app)
        let field = app.textFields["Title"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(title)
    }

    private func reopen(_ app: XCUIApplication, title: String) {
        app.typeKey("k", modifierFlags: .command)
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "⌘K must open the palette")
        search.tap()
        search.typeText(title)
        let row = element(app, "palette-row-\(title)")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the palette must find the saved task")
        row.tap()
        XCTAssertTrue(editor(app).waitForExistence(timeout: 5), "the palette row must reopen the editor")
    }

    /// Scrolls the form until the element is on screen. The drag starts high in the form because
    /// the software keyboard covers the middle of the sheet, where a swipe types instead of scrolls.
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        let showAll = app.buttons["Show all details"]
        if showAll.exists && !(target.exists && target.isHittable) { showAll.tap() }
        let form = editor(app)
        for _ in 0..<12 where !(target.exists && target.isHittable) {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.05)))
        }
        XCTAssertTrue(target.isHittable, "could not scroll to \(target)")
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement { element(app, "task-editor") }

    private func cards(_ app: XCUIApplication, title: String) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'task-card-' AND label CONTAINS %@", title))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
}
