import UIKit
import XCTest

/// Visual baseline for the iOS 27 refresh: one PNG per screen, light and dark, on iPhone, iPad,
/// and Mac Catalyst. Launches the seeded app with a frozen clock so every run shows the same
/// cards and relative dates. NOT a correctness test. Driven by `scripts/capture-screens.sh`.
///
/// Env (TEST_RUNNER_-prefixed on the xcodebuild side):
///   BASELINE=1             run at all (a plain GSDScreenshots run skips this class)
///   SCREENSHOT_DIR         output directory on the host
///   SCREENSHOT_PREFIX      filename prefix, e.g. "iphone-light-"
///   SCREENSHOT_APPEARANCE  light|dark (default light)
@MainActor
final class RefreshBaseline: XCTestCase {
    /// A fixed Friday, 2026-09-11 17:00 UTC (the same fallback DemoChoreography uses).
    private static let epoch = 1_789_146_000

    /// Where the PNGs go. The Mac Catalyst runner is sandboxed (read-only outside its container),
    /// so there it writes to its own temporary directory and `scripts/capture-screens.sh` copies
    /// the files out; the simulators write straight to the host path.
    private let dir: String = {
        #if targetEnvironment(macCatalyst)
        return NSTemporaryDirectory() + "gsd-screens"
        #else
        return ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/gsd-screens"
        #endif
    }()
    private let prefix = ProcessInfo.processInfo.environment["SCREENSHOT_PREFIX"] ?? ""

    override func setUpWithError() throws {
        // A screen that fails to appear should not lose the screens after it.
        continueAfterFailure = true
        guard ProcessInfo.processInfo.environment["BASELINE"] == "1" else {
            throw XCTSkip("baseline runs only with TEST_RUNNER_BASELINE=1")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        print("RefreshBaseline writes to \(dir)")
    }

    func testCaptureEveryScreen() throws {
        let appearance = ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] ?? "light"
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed",
                               "--demo-clock", "\(Self.epoch)",
                               "--demo-appearance", appearance]
        #if targetEnvironment(macCatalyst)
        app.launch()
        try walkRegular(app)
        #else
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            pause(1.5)   // launching sooner trips a transient accessibility error on the springboard
            app.launch()
            try walkRegular(app)
        } else {
            app.launch()
            try walkCompact(app)
        }
        #endif
    }

    // MARK: - iPhone (compact TabView)

    private func walkCompact(_ app: XCUIApplication) throws {
        let tabs = app.tabBars.firstMatch
        XCTAssertTrue(tabs.waitForExistence(timeout: 25), "tab bar never appeared")
        selectTab(app, "Matrix")
        XCTAssertTrue(card(app, "demo-investor").waitForExistence(timeout: 45), "seeded cards never appeared")   // a cold first launch seeds slowly
        pause(1.5)
        save(app, "01-matrix")

        app.swipeUp(velocity: .slow); pause(1.2)
        save(app, "02-matrix-scrolled")
        app.swipeDown(velocity: .slow); pause(1.0)

        swipeReveal(app)
        openEditor(app, dragToTop: true)

        selectTab(app, "Browse")
        save(app, "05-browse")
        if tap(row(app, "This Week"), "This Week row") { save(app, "06-smartview"); goBack(app) }
        if tap(element(app, label: "Archive"), "Archive row") { save(app, "07-archive"); goBack(app) }

        selectTab(app, "Dashboard"); pause(1.8)   // charts animate in
        save(app, "08-dashboard")
        app.swipeUp(velocity: .slow); pause(1.2)
        save(app, "09-dashboard-rings")

        selectTab(app, "Settings")
        save(app, "10-settings")
        settingsScreens(app)

        selectTab(app, "Matrix")
        openPalette(app)
        // The capture bar with a live parse preview: last, so the draft text and the keyboard
        // pollute nothing else.
        typeCapture(app)
    }

    // MARK: - iPad and Mac (NavigationSplitView)

    private func walkRegular(_ app: XCUIApplication) throws {
        XCTAssertTrue(app.textFields["capture-field"].waitForExistence(timeout: 25), "matrix never appeared")
        XCTAssertTrue(card(app, "demo-investor").waitForExistence(timeout: 45), "seeded cards never appeared")   // a cold first launch seeds slowly
        pause(1.5)
        save(app, "01-matrix")

        #if !targetEnvironment(macCatalyst)
        swipeReveal(app)   // touch only: Catalyst has no swipe gesture
        #endif
        openEditor(app, dragToTop: false)

        if tap(row(app, "This Week"), "This Week row") { save(app, "05-smartview") }

        if tap(sidebar(app, "Dashboard"), "Dashboard row") {
            pause(2.0)   // charts animate in
            save(app, "06-dashboard")
            #if !targetEnvironment(macCatalyst)
            app.swipeUp(velocity: .slow); pause(1.2)   // touch only: a swipe on the Mac has no hit point
            save(app, "07-dashboard-rings")
            #endif
        }
        if tap(sidebar(app, "Archive"), "Archive row") { save(app, "08-archive") }
        if tap(sidebar(app, "Settings"), "Settings row") {
            save(app, "09-settings")
            settingsScreens(app)
        }

        _ = tap(sidebar(app, "Matrix"), "Matrix row")
        openPalette(app)
        typeCapture(app)
    }

    // MARK: - Shared beats

    /// The swipe reveal open on the Complete action (native list swipe on iPhone, the
    /// hand-rolled reveal on iPad), then closed again without acting.
    private func swipeReveal(_ app: XCUIApplication) {
        let investor = card(app, "demo-investor")
        guard tap(investor, "investor card", tapping: false) else { return }
        investor.swipeRight(); pause(1.0)
        save(app, "03-swipe-reveal")
        // Tapping the open row closes it on both platforms without opening anything.
        investor.tap(); pause(1.0)
    }

    private func openEditor(_ app: XCUIApplication, dragToTop: Bool, dismiss: Bool = true) {
        let deck = card(app, "demo-deck")
        guard tap(deck, "deck card", tapping: false) else { return }
        // Tap inside the title area rather than the element's centre: on the Mac the centre of
        // the combined card element resolves to no hit point.
        deck.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap(); pause(1.2)
        var editor = element(app, "task-editor")
        if !editor.waitForExistence(timeout: 3) {
            deck.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.3)).tap()   // a leftover swipe state eats the first tap
            editor = element(app, "task-editor")
        }
        guard editor.waitForExistence(timeout: 5) else { XCTFail("editor never opened"); return }
        pause(0.8)
        if dragToTop {
            // The iPhone editor opens at the medium detent; drag it to large so the whole form is in frame.
            let grab = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56))
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            grab.press(forDuration: 0.1, thenDragTo: top); pause(1.0)
        }
        save(app, "04-editor")
        if dismiss { _ = tap(app.buttons["editor-cancel"].firstMatch, "editor Cancel") }
    }

    // MARK: - Widths (Mac)

    /// Mac only: the matrix at three window widths (compact, just above the boundary, regular),
    /// then the compact/regular swap while the editor is open, which must survive it. Env
    /// WIDTHS=1; a plain run skips it. The app is pinned with `--demo-window` and moved with
    /// the DemoWindow Darwin notifications.
    func testCaptureWidths() throws {
        #if targetEnvironment(macCatalyst)
        guard ProcessInfo.processInfo.environment["WIDTHS"] == "1" else {
            throw XCTSkip("widths run only with TEST_RUNNER_WIDTHS=1")
        }
        for (label, size) in [("w420", "420x860"), ("w700", "700x860"), ("w1100", "1100x860")] {
            let app = launchPinned(size)
            save(app, "\(label)-matrix")
            app.terminate()
        }
        let app = launchPinned("1100x860")
        // ⌘N (File ▸ New Task) opens the root editor sheet; a card tap does not register on the Mac.
        app.typeKey("n", modifierFlags: .command); pause(1.5)
        XCTAssertTrue(element(app, "task-editor").waitForExistence(timeout: 5), "editor never opened")
        save(app, "swap-regular-before")
        post("dev.vinny.gsd.demo.window.compact"); pause(2.5)
        XCTAssertTrue(element(app, "task-editor").exists, "the editor did not survive the swap to compact")
        save(app, "swap-compact-editor")
        post("dev.vinny.gsd.demo.window.regular"); pause(2.5)
        XCTAssertTrue(element(app, "task-editor").exists, "the editor did not survive the swap back")
        save(app, "swap-regular-editor")
        #else
        throw XCTSkip("widths run on the Mac")
        #endif
    }

    private func launchPinned(_ size: String) -> XCUIApplication {
        let appearance = ProcessInfo.processInfo.environment["SCREENSHOT_APPEARANCE"] ?? "light"
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-clock", "\(Self.epoch)",
                               "--demo-appearance", appearance, "--demo-window", size]
        app.launch()
        XCTAssertTrue(card(app, "demo-investor").waitForExistence(timeout: 45), "seeded cards never appeared")
        pause(1.5)
        return app
    }

    private func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(name as CFString), nil, nil, true)
    }

    /// Help (a sheet) and Feedback (a push) from the bottom of the Settings list. The list is
    /// lazy, so the rows exist only once scrolled into view.
    private func settingsScreens(_ app: XCUIApplication) {
        if tap(scrollTo(app, element(app, label: "How to use GSD")), "How to use GSD row") {
            save(app, "11-help")
            closeSheet(app)
        }
        if tap(scrollTo(app, element(app, label: "Feedback")), "Feedback row") {
            save(app, "12-feedback")
            goBack(app)
        }
    }

    private func openPalette(_ app: XCUIApplication) {
        guard tap(app.buttons["Search"].firstMatch, "Search button") else { return }
        save(app, "13-palette")
        _ = tap(app.buttons["Close"].firstMatch, "palette Close")
    }

    private func typeCapture(_ app: XCUIApplication) {
        let field = app.textFields["capture-field"]
        guard tap(field, "capture field") else { return }
        field.typeText("Call the plumber !! #home"); pause(1.0)
        save(app, "14-capture")
    }

    // MARK: - Navigation helpers

    /// Switches tabs. After a scroll the floating tab bar minimizes to the active tab and the
    /// other tab buttons leave the accessibility tree; a tap on the minimized bar expands it.
    private func selectTab(_ app: XCUIApplication, _ name: String) {
        let bar = app.tabBars.firstMatch
        let button = bar.buttons[name]
        if !button.exists, bar.buttons.firstMatch.exists {
            bar.buttons.firstMatch.tap(); pause(0.8)
        }
        guard tap(button, "\(name) tab") else { return }
    }

    /// Waits for `element`, taps it (unless `tapping` is false), and pauses. A miss records a
    /// failure and returns false so the walk skips that screen instead of aborting.
    @discardableResult
    private func tap(_ element: XCUIElement, _ what: String, tapping: Bool = true) -> Bool {
        guard element.waitForExistence(timeout: 5) else {
            XCTFail("\(what) not found")
            return false
        }
        if tapping {
            element.tap()
            pause(1.2)
        }
        return true
    }

    /// Scrolls (at most four times) until `element` is in the accessibility tree.
    private func scrollTo(_ app: XCUIApplication, _ element: XCUIElement) -> XCUIElement {
        for _ in 0..<4 where !element.exists {
            #if targetEnvironment(macCatalyst)
            app.typeKey(.pageDown, modifierFlags: [])
            #else
            app.swipeUp(velocity: .fast)
            #endif
            pause(0.6)
        }
        return element
    }

    private func goBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.element(boundBy: 0)
        if back.waitForExistence(timeout: 3) { back.tap() }
        pause(1.0)
    }

    /// Dismisses the Help sheet: its Close button, or Esc on the Mac.
    private func closeSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 3) {
            close.tap()
        } else {
            #if targetEnvironment(macCatalyst)
            app.typeKey(.escape, modifierFlags: [])
            #endif
        }
        pause(1.0)
    }

    /// A sidebar destination row (iPad and Mac), matched by its label.
    private func sidebar(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// A smart-view row, whose accessibility label is "<name>, <count> tasks".
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", name + ",")).firstMatch
    }

    private func element(_ app: XCUIApplication, label: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Resolves an accessibility identifier regardless of the element's reported type.
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The card for a seeded task id, falling back to its title (see DemoChoreography.card).
    private func card(_ app: XCUIApplication, _ taskID: String) -> XCUIElement {
        let byID = element(app, "task-card-\(taskID)")
        if byID.exists { return byID }
        let titles = ["demo-investor": "Reply to the investor email",
                      "demo-deck": "Finish the Q3 board deck"]
        let title = titles[taskID] ?? taskID
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }

    private func save(_ app: XCUIApplication, _ name: String) {
        #if targetEnvironment(macCatalyst)
        // The whole display on the Mac is mostly desktop; keep the app's window.
        let png = app.windows.firstMatch.screenshot().pngRepresentation
        #else
        let png = XCUIScreen.main.screenshot().pngRepresentation
        #endif
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(prefix)\(name).png")
        do {
            try png.write(to: url)
        } catch {
            XCTFail("could not write \(url.path): \(error)")
        }
    }
}
