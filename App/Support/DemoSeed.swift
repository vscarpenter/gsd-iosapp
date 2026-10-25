import Foundation
import GSDModel
import GSDStore

/// Seeds the marketing-video and screenshot fixtures when the app is launched with `--demo-seed`,
/// which only the XCUITest harness passes. The argument also flips `HarnessLaunch.isIsolated`,
/// so `GSDApp.init` has already opened an in-memory store, signed out, and pointed every shared
/// seam at scratch before this runs. `DemoFixtures.seed` refuses any non-empty store besides.
enum DemoSeed {
    static let launchArgument = "--demo-seed"

    /// True when this launch carries the flag.
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static func seedIfRequested(_ store: TaskStore, now: Date = .now) async {
        guard isRequested else { return }
        do {
            try await DemoFixtures.seed(into: store, now: now)
        } catch {
            // A harness run without its fixtures is worthless, and a refusal means the seed met a
            // store it must not touch. Either way the run stops here, at the reason.
            fatalError("[DemoSeed] seeding refused or failed: \(error)")
        }
    }
}
