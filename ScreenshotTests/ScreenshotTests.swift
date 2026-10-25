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
/// Launches with `--demo-seed`, so the app seeds its own fixtures into an in-memory store and
/// never opens the shared one (see `HarnessLaunch`).
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
        app.launchArguments = ["--demo-seed"]
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
        let row = seededDeckCard(app)
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
        let card = seededDeckCard(app)
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

    /// The Do First fixture the editor shot opens (`DemoFixtures`, id `demo-deck`), matched the
    /// way RefreshBaseline matches cards: by identifier, or by the label the title starts.
    private func seededDeckCard(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label BEGINSWITH %@",
            "task-card-demo-deck", "Finish the Q3 board deck")).firstMatch
    }

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

/// Opt-in functional smoke on a disposable simulator; never seeds or erases user data.
@MainActor
final class ReleaseReadinessTests: XCTestCase {
    func testCaptureAndEditorAccessibility() throws {
        guard ProcessInfo.processInfo.environment["RELEASE_QA"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RELEASE_QA=1 on a disposable QA simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let capture = app.textFields["capture-field"]
        XCTAssertTrue(capture.waitForExistence(timeout: 20))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion])
        capture.tap()
        capture.typeText("Accessibility draft *")
        app.buttons["capture-details"].tap()
        XCTAssertTrue(app.textFields["Title"].waitForExistence(timeout: 5))
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .hitRegion])
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Accessible editor"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["editor-cancel"].tap()
    }

    func testLargeTypeEditorHasRoomForContent() throws {
        guard ProcessInfo.processInfo.environment["RELEASE_QA"] == "1",
              ProcessInfo.processInfo.environment["LARGE_TYPE_QA"] == "1" else {
            throw XCTSkip("Run on a disposable simulator with accessibility text sizes enabled")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let capture = app.textFields["capture-field"]
        XCTAssertTrue(capture.waitForExistence(timeout: 20))
        capture.tap()
        capture.typeText("Large type draft !!")
        app.buttons["capture-details"].tap()
        let cancel = app.buttons["editor-cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertLessThan(cancel.frame.minY, app.frame.height / 3,
                          "Large text needs a full-height editor")
        XCTAssertFalse(app.buttons["Show all details"].exists,
                       "The expansion prompt must not cover the form at accessibility sizes")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Large-text editor presentation"
        shot.lifetime = .keepAlways
        add(shot)
        let schedule = app.buttons["Schedule"]
        for _ in 0..<4 where !schedule.isHittable { app.swipeUp() }
        XCTAssertTrue(schedule.isHittable, "Quadrants must remain reachable at large text sizes")
        schedule.tap()
        XCTAssertTrue(schedule.isSelected)
        cancel.tap()
    }

    /// Regression for the iPhone Duo's outer display (follow-up to the harness PR, 2026-10-25):
    /// once the editor's form scrolled, the sheet's title, Cancel, and Save left both the pixels
    /// and the accessibility tree. The test opens the editor from the capture bar, expands it,
    /// scrolls the form, and expects the bar to still be there. It passes on a plain iPhone.
    func testEditorBarSurvivesScroll() throws {
        guard ProcessInfo.processInfo.environment["RELEASE_QA"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RELEASE_QA=1 on a disposable QA simulator")
        }
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let capture = app.textFields["capture-field"]
        XCTAssertTrue(capture.waitForExistence(timeout: 20))
        capture.tap()
        capture.typeText("Editor bar draft")
        app.buttons["capture-details"].tap()
        let cancel = app.buttons["editor-cancel"]
        let save = app.buttons["editor-save"]
        let title = app.staticTexts["New Task"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(save.exists)
        XCTAssertTrue(title.exists)
        // A compact presenter opens at the medium detent; expand it the way a user would.
        let showAll = app.buttons["Show all details"]
        if showAll.exists {
            showAll.tap()
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(cancel.exists, "Cancel left after the sheet expanded")
        }
        let form = app.descendants(matching: .any).matching(identifier: "task-editor").firstMatch
        XCTAssertTrue(form.exists)
        form.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        attach(app, "Editor after one scroll")
        XCTAssertTrue(cancel.exists, "Cancel left after the form scrolled")
        XCTAssertTrue(save.exists, "Save left after the form scrolled")
        XCTAssertTrue(title.exists, "The title left after the form scrolled")
        form.swipeDown()
        Thread.sleep(forTimeInterval: 1)
        attach(app, "Editor scrolled back to the top")
        XCTAssertTrue(cancel.exists, "Cancel did not come back after scrolling to the top")
        if cancel.exists { cancel.tap() }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + " (hierarchy)"
        tree.lifetime = .keepAlways
        add(tree)
    }

    /// Review finding 4 (2026-10-24): the Field Guide used the device idiom to decide whether
    /// to list keyboard shortcuts, so an open iPhone Duo (phone idiom, regular-width root) hid
    /// them. The rule is now the presenter's width: a compact root hides the section and a
    /// regular root shows it. On iPhone and iPad that matches the old behavior, so this only
    /// turns red on the open Duo, where the owner runs it after unfolding the phone.
    func testHelpShortcutsFollowTheRootWidth() throws {
        guard ProcessInfo.processInfo.environment["RELEASE_QA"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RELEASE_QA=1 on a disposable QA simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        XCTAssertTrue(app.textFields["capture-field"].waitForExistence(timeout: 20))
        let compactRoot = app.tabBars.firstMatch.exists || app.buttons["Browse"].exists
        if compactRoot {
            let bar = app.tabBars.firstMatch
            (bar.exists ? bar.buttons["Settings"] : app.buttons["Settings"]).tap()
        } else {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Settings")).firstMatch.tap()
        }
        let guide = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "How to use GSD")).firstMatch
        for _ in 0..<4 where !guide.exists { app.swipeUp(velocity: .fast) }
        XCTAssertTrue(guide.waitForExistence(timeout: 5), "the How to use GSD row did not appear")
        guide.tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), "the Field Guide did not open")
        let shortcuts = app.staticTexts["KEYBOARD SHORTCUTS"]
        XCTAssertEqual(shortcuts.exists, !compactRoot,
                       compactRoot ? "a compact root must not list keyboard shortcuts"
                                   : "a regular root must list keyboard shortcuts")
        close.tap()
    }

    func testLocalTaskLifecycle() throws {
        guard ProcessInfo.processInfo.environment["RELEASE_QA"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_RELEASE_QA=1 on a disposable QA simulator")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let skip = app.buttons["Skip"]
        if skip.waitForExistence(timeout: 5) { skip.tap() }
        let capture = app.textFields["capture-field"]
        XCTAssertTrue(capture.waitForExistence(timeout: 20))
        let showCompleted = app.buttons["Show Completed"]
        XCTAssertTrue(showCompleted.waitForExistence(timeout: 5))
        let initiallyShowingCompleted = showCompleted.isSelected || showCompleted.value as? String == "1"
        if initiallyShowingCompleted { showCompleted.tap() }
        let title = "Release QA " + String(UUID().uuidString.prefix(8))
        capture.tap()
        capture.typeText(title + " !!\n")
        func card(_ text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(
                format: "identifier BEGINSWITH 'task-card-' AND label CONTAINS %@", text)).firstMatch
        }
        XCTAssertTrue(card(title).waitForExistence(timeout: 10))
        app.terminate()
        app.launch()
        XCTAssertTrue(card(title).waitForExistence(timeout: 15), "capture did not persist")
        card(title).tap()
        let titleField = app.textFields["Title"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        titleField.tap()
        titleField.typeText(" cancelled")
        app.buttons["editor-cancel"].tap()
        XCTAssertTrue(card(title).waitForExistence(timeout: 5))
        card(title).tap()
        XCTAssertEqual(titleField.value as? String, title, "Cancel saved the draft")
        titleField.tap()
        titleField.typeText(" edited")
        app.buttons["editor-save"].tap()
        XCTAssertTrue(card(title + " edited").waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(card(title + " edited").waitForExistence(timeout: 15), "edit did not persist")
        card(title + " edited").press(forDuration: 1)
        let complete = app.buttons["Complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        XCTAssertTrue(card(title + " edited").waitForNonExistence(timeout: 5))
        showCompleted.tap()
        XCTAssertTrue(card(title + " edited").waitForExistence(timeout: 5))
        card(title + " edited").press(forDuration: 1)
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        XCTAssertTrue(card(title + " edited").waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Local task persisted after relaunch"
        shot.lifetime = .keepAlways
        add(shot)
        if !initiallyShowingCompleted { showCompleted.tap() }
    }
}
