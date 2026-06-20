import Foundation
import SwiftUI

/// Demo-mode launch arguments for the marketing / App-Store video harness. Every flag is a no-op
/// unless explicitly passed, so the production launch path is byte-identical to today — only the
/// XCUITest choreography (`ScreenshotTests/DemoChoreography`) passes these.
enum DemoLaunch {
    /// `--demo-clock <epoch-seconds>` — freezes "now" so seeded due dates and the dashboard
    /// trend render identically on every take, even months apart.
    static let clockArgument = "--demo-clock"
    /// `--demo-appearance <light|dark>` — forces the color scheme regardless of the saved theme.
    static let appearanceArgument = "--demo-appearance"

    /// The frozen instant, or `nil` in a normal launch.
    static var clock: Date? {
        value(after: clockArgument).flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
    }

    /// The forced color scheme, or `nil` to honor the user's saved theme.
    static var appearance: ColorScheme? {
        switch value(after: appearanceArgument)?.lowercased() {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    /// The argument value immediately following `flag`, or `nil` if absent.
    private static func value(after flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
}

private struct DemoClockKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// A fixed "now" pinned by the demo-video harness, or `nil` to use the live clock. Consumers
    /// fall back to their own live source (a `TimelineView` date, `.now`) when this is `nil`, so
    /// production behavior is unchanged.
    var demoClock: Date? {
        get { self[DemoClockKey.self] }
        set { self[DemoClockKey.self] = newValue }
    }
}

extension View {
    /// Pins `\.demoClock` for the demo harness. Injecting `nil` (production) equals the default.
    func demoClock(_ date: Date?) -> some View { environment(\.demoClock, date) }
}
