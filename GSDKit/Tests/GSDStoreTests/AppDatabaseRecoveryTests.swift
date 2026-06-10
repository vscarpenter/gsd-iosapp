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
