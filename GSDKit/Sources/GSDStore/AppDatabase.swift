import Foundation
import GRDB

/// Owns the GRDB writer and applies migrations on init. Construct once and share.
public final class AppDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// On-disk database at the shared store location.
    public static func live() throws -> AppDatabase {
        let url = try StoreLocation.databaseURL()
        return try AppDatabase(try DatabaseQueue(path: url.path))
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
            return try AppDatabase(try DatabaseQueue(path: url.path))
        } catch {
            // Move the main file + SQLite sidecars aside (a fresh DB must not inherit a stale WAL).
            for suffix in ["", "-wal", "-shm"] {
                let src = url.path + suffix
                guard fileManager.fileExists(atPath: src) else { continue }
                let dst = src + ".corrupt"
                if fileManager.fileExists(atPath: dst) { try? fileManager.removeItem(atPath: dst) }
                try? fileManager.moveItem(atPath: src, toPath: dst)
            }
            return try AppDatabase(try DatabaseQueue(path: url.path))
        }
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }
}
