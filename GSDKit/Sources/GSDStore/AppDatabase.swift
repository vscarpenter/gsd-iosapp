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

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(try DatabaseQueue())
    }
}
