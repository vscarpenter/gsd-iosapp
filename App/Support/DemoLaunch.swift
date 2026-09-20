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

/// Mac Catalyst screenshot harness: `--demo-window <width>x<height>` pins the window to an
/// exact size, and two Darwin notifications move it across the compact/regular boundary while
/// the app runs, so the root swap can be captured with state in flight (iPhone apps resize on
/// iOS 27; on the Mac the window is the one place a size class can cross in a test). Every hook
/// is inert without the argument.
enum DemoWindow {
    static let argument = "--demo-window"
    static let compactNotification = "dev.vinny.gsd.demo.window.compact"
    static let regularNotification = "dev.vinny.gsd.demo.window.regular"
    static let compact = CGSize(width: 420, height: 860)
    static let regular = CGSize(width: 1100, height: 860)

    /// The pinned size from the launch argument, or `nil` in a normal launch.
    static var requested: CGSize? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: argument), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    #if targetEnvironment(macCatalyst)
    @MainActor private static var scene: UIWindowScene?

    /// Pins `scene` to `size` and listens for the resize notifications. Call once per scene.
    @MainActor static func pin(_ windowScene: UIWindowScene, to size: CGSize) {
        scene = windowScene
        apply(size)
        for name in [compactNotification, regularNotification] {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(), nil,
                { _, _, name, _, _ in
                    let posted = name.map { $0.rawValue as String }
                    _Concurrency.Task { @MainActor in DemoWindow.handle(posted) }
                },
                name as CFString, nil, .deliverImmediately)
        }
    }

    @MainActor private static func handle(_ notification: String?) {
        switch notification {
        case compactNotification: apply(compact)
        case regularNotification: apply(regular)
        default: break
        }
    }

    @MainActor private static func apply(_ size: CGSize) {
        scene?.sizeRestrictions?.minimumSize = size
        scene?.sizeRestrictions?.maximumSize = size
    }
    #endif
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
