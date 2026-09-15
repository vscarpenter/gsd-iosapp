import XCTest

/// Sets the iOS 27 Liquid Glass appearance through the Settings app on the simulator, so the
/// refresh screens can be captured at both ends of the user control (and put back to the
/// default afterwards). NOT a correctness test. Driven by `scripts/capture-screens.sh`.
///
/// Env (TEST_RUNNER_-prefixed on the xcodebuild side):
///   GLASS           clear | tinted | default, or a 0...1 slider position
///   SCREENSHOT_DIR  where the "glass-<value>.png" record of the Settings page goes
@MainActor
final class GlassSetting: XCTestCase {
    func testSetLiquidGlass() throws {
        guard let target = ProcessInfo.processInfo.environment["GLASS"], !target.isEmpty else {
            throw XCTSkip("runs only with TEST_RUNNER_GLASS=<clear|tinted|default|0...1>")
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        // Settings search has no index for "Liquid Glass" on a fresh simulator, so go through
        // the Display & Brightness page and look for the control by name there.
        XCTAssertTrue(openDisplayAndBrightness(settings), "Display & Brightness page not found")
        describeControls(settings)
        XCTAssertTrue(openRow(settings, containing: "glass"), "no Liquid Glass row on the Display page")
        pause(1.0)
        describeControls(settings)
        apply(target, in: settings)
        pause(1.0)
        describeControls(settings)
        save(settings, "glass-\(target)")
    }

    // MARK: - Steps

    /// Jumps to a Settings page through the root search field. The root list is lazy and
    /// restores its last scroll position across launches, so scrolling for a row is unreliable;
    /// the search result is one tap away regardless.
    private func openViaSearch(_ app: XCUIApplication, _ query: String) -> Bool {
        let field = app.searchFields.firstMatch
        guard field.waitForExistence(timeout: 5) else { return false }
        field.tap(); pause(0.6)
        field.typeText(query); pause(1.5)
        let result = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", query)).firstMatch
        guard result.waitForExistence(timeout: 5) else { return false }
        result.tap(); pause(1.2)
        return true
    }

    /// The Display & Brightness page: through search when the index answers, else from the
    /// top of the root list, stepping down a third of a screen at a time.
    private func openDisplayAndBrightness(_ app: XCUIApplication) -> Bool {
        if openViaSearch(app, "Display") { return true }
        app.buttons["close"].firstMatch.tap(); pause(0.5)   // leave search
        // The root list restores its last position (often the bottom), so scan upward in
        // half-screen drags, then downward, until the row is in the lazy list's tree.
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Display")).firstMatch
        for step in 0..<24 where !row.exists {
            let up = step < 12
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.3 : 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.8 : 0.3))
            from.press(forDuration: 0.05, thenDragTo: to); pause(0.7)
        }
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap(); pause(1.2)
        return true
    }

    /// Taps the first row on the current page whose label contains `text`.
    private func openRow(_ app: XCUIApplication, containing text: String) -> Bool {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
        for _ in 0..<6 where !row.exists {
            app.swipeUp(velocity: .slow); pause(0.6)
        }
        guard row.waitForExistence(timeout: 5) else { return false }
        row.tap(); pause(1.2)
        return true
    }

    /// Moves the control to the requested end. A slider takes a normalized position; a set
    /// of buttons (Clear / Tinted) takes the matching label.
    private func apply(_ target: String, in app: XCUIApplication) {
        let slider = app.sliders.firstMatch
        if slider.exists {
            let position: CGFloat
            switch target {
            case "clear": position = 0
            case "tinted": position = 1
            case "default": position = 0.5
            default: position = CGFloat(Double(target) ?? 0.5)
            }
            slider.adjust(toNormalizedSliderPosition: position)
            return
        }
        let button = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label ==[c] %@", target)).firstMatch
        if button.waitForExistence(timeout: 3) {
            button.tap()
        } else {
            XCTFail("no slider and no control labelled '\(target)' on the Liquid Glass page")
        }
    }

    /// Logs every control on the page (type, label, value) so the walk can be adjusted when
    /// the Settings layout changes.
    private func describeControls(_ app: XCUIApplication) {
        let types: [(String, XCUIElementQuery)] = [
            ("slider", app.sliders), ("switch", app.switches), ("button", app.buttons),
            ("segmented", app.segmentedControls), ("text", app.staticTexts),
        ]
        for (name, query) in types {
            for element in query.allElementsBoundByIndex.prefix(30) {
                print("GlassSetting \(name): label='\(element.label)' value='\(element.value ?? "")'")
            }
        }
    }

    private func save(_ app: XCUIApplication, _ name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).png")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
    }

    private func pause(_ seconds: TimeInterval) { Thread.sleep(forTimeInterval: seconds) }
}
