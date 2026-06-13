import Testing
import Foundation
import GRDB
@testable import GSDStore

struct AppDatabaseRecoveryTests {
    private func tempDBURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gsd-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gsd.sqlite")
    }

    @Test func opensCleanlyWhenNoFileExists() throws {
        let url = try tempDBURL()
        _ = try AppDatabase.openWithRecovery(at: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func transientLockErrorsAreRethrownNotRecovered() throws {
        // A second connection hitting SQLITE_BUSY/LOCKED is contention, not corruption —
        // recovery here would move a HEALTHY database aside and wipe the user's data.
        let url = try tempDBURL()
        _ = try AppDatabase.openWithRecovery(at: url)   // create + migrate a healthy store
        let holder = try DatabaseQueue(path: url.path)
        try holder.inDatabase { db in
            try db.execute(sql: "BEGIN EXCLUSIVE TRANSACTION")
            #expect(throws: (any Error).self) { try AppDatabase.openWithRecovery(at: url) }
            try db.execute(sql: "ROLLBACK")
        }
        // The healthy store was left alone…
        #expect(!FileManager.default.fileExists(atPath: url.path + ".corrupt"))
        // …and still opens once the lock clears.
        _ = try AppDatabase.openWithRecovery(at: url)
    }

    @Test func corruptFileIsMovedAsideAndAFreshStoreCreated() throws {
        let url = try tempDBURL()
        try Data("this is not a sqlite database".utf8).write(to: url)
        let db = try AppDatabase.openWithRecovery(at: url)
        // The fresh store is usable (migrations applied)…
        try db.writer.read { db in _ = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tasks") }
        // …and the bad file is preserved for recovery, not deleted.
        let corrupt = url.path + ".corrupt"
        #expect(FileManager.default.fileExists(atPath: corrupt))
        #expect(try Data(contentsOf: URL(fileURLWithPath: corrupt)) == Data("this is not a sqlite database".utf8))
    }
}
