import Testing
import Foundation
@testable import GSDSync

struct SyncCursorTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.synccursor.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!; d.removePersistentDomain(forName: suite); return d
    }

    @Test func unsetCursorIsNil() {
        #expect(SyncCursor(defaults: freshDefaults()).load() == nil)
    }

    @Test func advanceWritesPocketBaseFormMinusFiveSeconds() throws {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_000))
        let stored = try #require(cursor.load())
        #expect(stored.contains(" ") && !stored.contains("T"))      // PB space form
        let date = try #require(WireDate.parse(stored))
        #expect(Int(date.timeIntervalSince1970) == 1_000_000_000 - 5)
    }

    @Test func advanceNoOpWhenMaxAppliedNil() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: nil)
        #expect(cursor.load() == nil)
    }

    @Test func legacyClientCursorMigratesWithDayRewind() throws {
        let defaults = freshDefaults()
        defaults.set("2026-06-10T12:00:00.000Z", forKey: "gsd.sync.lastSyncAt")
        let stored = try #require(SyncCursor(defaults: defaults).load())
        let date = try #require(WireDate.parse(stored))
        let expected = try #require(WireDate.parse("2026-06-10T12:00:00.000Z"))
        #expect(date == expected.addingTimeInterval(-24 * 60 * 60))
        #expect(stored.contains(" "))                                // re-emitted in PB form
    }

    @Test func advanceRetiresTheLegacyKey() {
        let defaults = freshDefaults()
        defaults.set("2026-06-10T12:00:00.000Z", forKey: "gsd.sync.lastSyncAt")
        SyncCursor(defaults: defaults).advance(maxApplied: Date(timeIntervalSince1970: 2_000_000_000))
        #expect(defaults.string(forKey: "gsd.sync.lastSyncAt") == nil)
        #expect(SyncCursor(defaults: defaults).load() != nil)
    }

    @Test func clearRemovesBothKeys() {
        let defaults = freshDefaults()
        defaults.set("legacy", forKey: "gsd.sync.lastSyncAt")
        let cursor = SyncCursor(defaults: defaults)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1000))
        cursor.clear()
        #expect(cursor.load() == nil)
        #expect(defaults.string(forKey: "gsd.sync.lastSyncAt") == nil)
    }
}
