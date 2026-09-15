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
        XCTAssertTrue(open(settings, "Display & Brightness"), "Display & Brightness row not found")
        XCTAssertTrue(open(settings, "Liquid Glass"), "Liquid Glass row not found")
        pause(1.0)
        describeControls(settings)
        apply(target, in: settings)
        pause(1.0)
        describeControls(settings)
        save(settings, "glass-\(target)")
    }

    // MARK: - Steps

    /// Taps the Settings row with this label, scrolling the (lazy) list a third of a screen at
    /// a time until the row exists, so a long list is not overshot.
    private func open(_ app: XCUIApplication, _ label: String) -> Bool {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label)).firstMatch
        for _ in 0..<12 where !row.exists {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            from.press(forDuration: 0.05, thenDragTo: to); pause(0.6)
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
