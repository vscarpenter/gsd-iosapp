import Foundation
import GRDB

/// Owns the GRDB writer and applies migrations on init. Construct once and share.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Shared GRDB configuration for every connection we open. `observesSuspensionNotifications`
    /// is the mitigation for the `0xDEAD10CC` watchdog kill: when the app posts
    /// `AppDatabase.suspend()` on backgrounding, GRDB releases the SQLite write lock (in-flight and
    /// subsequent writes then throw `SQLITE_INTERRUPT`/`SQLITE_ABORT`, which the sync paths already
    /// swallow) so iOS won't terminate us for holding a lock across suspension. `resume()` restores writes.
    static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.observesSuspensionNotifications = true
        return config
    }

    /// On-disk database at the shared store location.
    public static func live() throws -> AppDatabase {
        let url = try StoreLocation.databaseURL()
        return try AppDatabase(try DatabaseQueue(path: url.path, configuration: makeConfiguration()))
    }

    /// `live()` with a recovery path: an unopenable store (corruption, failed migration) is
    /// moved aside — PRESERVED as `<name>.corrupt` for manual recovery, never deleted — and a
    /// fresh store is created. A data app must not crash-loop at launch with no way out short
    /// of deleting the app (which destroys the very data the bad file might still yield).
    public static func liveWithRecovery(fileManager: FileManager = .default) throws -> AppDatabase {
        try openWithRecovery(at: try StoreLocation.databaseURL(), fileManager: fileManager)
    }

    static func openWithRecovery(at url: URL, fileManager: FileManager = .default) throws -> AppDatabase {
        do {
            return try AppDatabase(try DatabaseQueue(path: url.path, configuration: makeConfiguration()))
        } catch let error as DatabaseError where error.resultCode == .SQLITE_BUSY || error.resultCode == .SQLITE_LOCKED {
            // Contention from another live connection on the same file — the store is
            // HEALTHY; moving it aside here would wipe the user's data. Let the caller fail.
            throw error
        } catch {
            // Move the main file + SQLite sidecars aside (a fresh DB must not inherit a stale WAL).
            for suffix in ["", "-wal", "-shm"] {
                let src = url.path + suffix
                guard fileManager.fileExists(atPath: src) else { continue }
                let dst = src + ".corrupt"
                if fileManager.fileExists(atPath: dst) { try? fileManager.removeItem(atPath: dst) }
                try? fileManager.moveItem(atPath: src, toPath: dst)
            }
            return try AppDatabase(try DatabaseQueue(path: url.path, configuration: makeConfiguration()))
        }
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue(configuration: makeConfiguration()))
    }

    // MARK: - Suspension (0xDEAD10CC mitigation)

    /// Post when the app is about to be suspended (scenePhase → `.background`). Releases SQLite
    /// write locks on every connection that observes suspension, so iOS does not terminate the app
    /// for holding a lock across suspension. Pair with `resume()` on return to the foreground.
    public static func suspend() {
        NotificationCenter.default.post(name: Database.suspendNotification, object: nil)
    }

    /// Post when the app becomes active again (scenePhase → `.active`) to restore normal writes.
    public static func resume() {
        NotificationCenter.default.post(name: Database.resumeNotification, object: nil)
    }
}
