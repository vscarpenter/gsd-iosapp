import Testing
import Foundation
import GRDB
@testable import GSDStore

/// Regression guard for the 0xDEAD10CC crash: a database connection must observe the
/// suspend/resume notifications so iOS does not terminate the app for holding a SQLite
/// write lock across suspension (see AppDatabase.makeConfiguration). Tests the real
/// construction path — not a bare Configuration — so removing the flag from any opener fails.
struct DatabaseSuspensionConfigTests {
    private func tempDBURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsd-suspend-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gsd.sqlite")
    }

    @Test func openedDatabaseObservesSuspensionNotifications() throws {
        let database = try AppDatabase.openWithRecovery(at: try tempDBURL())
        #expect(database.writer.configuration.observesSuspensionNotifications)
    }

    @Test func inMemoryDatabaseObservesSuspensionNotifications() throws {
        let database = try AppDatabase.inMemory()
        #expect(database.writer.configuration.observesSuspensionNotifications)
    }
}
