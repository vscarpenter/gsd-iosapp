import Foundation

/// The one switch every screenshot and video harness launch flips. Any `--demo-` argument
/// (`--demo-seed`, `--demo-home`, `--demo-clock`, `--demo-appearance`, `--demo-window`) marks
/// the process as a harness run, and a harness run must never touch what the real app owns: the
/// App Group database and defaults, the keychain session, the share outbox, the widget snapshot,
/// reminders, and Spotlight. A dev-signed Catalyst build shares every one of those with the
/// installed app, which is how the 2026-10-24 seed reached the owner's real tasks.
public enum HarnessLaunch {
    public static let argumentPrefix = "--demo-"
    /// Never the App Group suite, so `@AppStorage(store: .shared)` and the store's settings read
    /// and write a suite the real app never opens.
    public static let defaultsSuiteName = "dev.vinny.gsd.harness"

    /// True when this process was launched by the harness. Decided once, before anything is built.
    public static let isIsolated: Bool = isolates(arguments: ProcessInfo.processInfo.arguments)

    public static func isolates(arguments: [String]) -> Bool {
        arguments.contains { $0.hasPrefix(argumentPrefix) }
    }

    /// A defaults suite that starts empty on every launch.
    public static func makeIsolatedDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: defaultsSuiteName) ?? .standard
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        return defaults
    }

    /// A per-process folder for the file-backed seams: the share outbox and the widget snapshot.
    public static let scratchDirectory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsd-harness-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
}
