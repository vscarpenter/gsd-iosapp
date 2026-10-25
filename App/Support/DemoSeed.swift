import Foundation
import GSDModel
import GSDStore

/// Seeds the marketing-video and screenshot fixtures when the app is launched with `--demo-seed`,
/// which only the XCUITest harness passes. `GSDApp.init` answers the same flag by opening an
/// in-memory store and running signed out, so the seed never reaches real data or the server;
/// `DemoFixtures.seed` refuses a store that holds anything but its own fixtures besides.
enum DemoSeed {
    static let launchArgument = "--demo-seed"

    /// True when this launch carries the flag. Read in `GSDApp.init`, before the store exists.
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains(launchArgument) }

    static func seedIfRequested(_ store: TaskStore, now: Date = .now) async {
        guard isRequested else { return }
        UserDefaults(suiteName: AppGroup.id)?.set(true, forKey: "hasOnboarded")
        do {
            try await DemoFixtures.seed(into: store, now: now)
        } catch {
            print("[DemoSeed] seeding refused or failed: \(error)")   // best-effort; an empty matrix is the worst case
        }
    }
}
