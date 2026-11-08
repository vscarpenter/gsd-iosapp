import Foundation

/// Runs background work that reads or writes the store (a watch command landing while the phone
/// app is backgrounded). The app suspends the database in the background as the `0xDEAD10CC`
/// mitigation, and a suspended database rejects every read and write. So: resume if the app is
/// backgrounded, and on the way out suspend only if it is *still* backgrounded, because a run
/// that ends as the user opens the app must not lock out the live UI. The app passes an
/// `isBackgrounded` that is always false on Mac Catalyst, which never suspends.
@MainActor
public struct BackgroundDatabaseWindow {
    private let isBackgrounded: @MainActor () -> Bool
    private let resume: @MainActor () -> Void
    private let suspend: @MainActor () -> Void

    public init(isBackgrounded: @escaping @MainActor () -> Bool,
                resume: @escaping @MainActor () -> Void = AppDatabase.resume,
                suspend: @escaping @MainActor () -> Void = AppDatabase.suspend) {
        self.isBackgrounded = isBackgrounded
        self.resume = resume
        self.suspend = suspend
    }

    public func run<R>(_ body: () async throws -> R) async rethrows -> R {
        let backgrounded = isBackgrounded()
        if backgrounded { resume() }
        defer { if backgrounded && isBackgrounded() { suspend() } }
        return try await body()
    }
}
