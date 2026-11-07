import Testing
import Foundation
@testable import GSDSync
@testable import GSDWire

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

// MARK: Pull contract (a newly synced field reaches rows an older build already pulled)

extension SyncCursorTests {
    /// C4-1: an older build that signed out has no cursor, and its rows still lack the field.
    @Test func aMissingContractNeedsBackfillWithoutACursor() {
        let cursor = SyncCursor(defaults: freshDefaults())
        #expect(cursor.load() == nil)
        #expect(cursor.storedVersion() == 0)
        #expect(cursor.needsBackfill())
    }

    @Test func cursorWrittenBeforeTheContractNeedsBackfill() {
        let defaults = freshDefaults()
        defaults.set("2026-10-27 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated")   // an older build's cursor
        #expect(SyncCursor(defaults: defaults).needsBackfill())
    }

    @Test func legacyClientCursorNeedsBackfill() {
        let defaults = freshDefaults()
        defaults.set("2026-06-10T12:00:00.000Z", forKey: "gsd.sync.lastSyncAt")
        #expect(SyncCursor(defaults: defaults).needsBackfill())
    }

    @Test func markBackfilledStampsTheContract() {
        let defaults = freshDefaults()
        defaults.set("2026-10-27 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated")
        let cursor = SyncCursor(defaults: defaults)
        cursor.markBackfilled()
        #expect(!cursor.needsBackfill())
        #expect(cursor.load() != nil)                                  // the cursor itself is untouched
    }

    @Test func advanceStampsTheContractSoAFreshInstallNeverBackfills() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_000))
        #expect(!cursor.needsBackfill())
    }

    /// C4-1, C4-3: sign-out forgets the cursor, and only a completed pull changes the version.
    @Test func clearKeepsTheContract() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_000))
        cursor.clear()
        #expect(cursor.load() == nil)
        #expect(cursor.storedVersion() == SyncCursor.contractVersion)
        #expect(!cursor.needsBackfill())
    }

    /// SPEC-3 (#680), iOS storage: the remembered ids have their own key, and sign-out's `clear()`
    /// removes only the cursor's own keys, so they survive it.
    @Test func clearKeepsTheRememberedDeletes() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_000))
        cursor.rememberDeletes(["t1"])
        cursor.clear()
        #expect(cursor.load() == nil)
        #expect(cursor.rememberedDeletes() == ["t1"])
    }

    @Test func clearLeavesAnOlderContractOwed() {
        let defaults = freshDefaults()
        defaults.set("2026-10-27 00:00:00.000Z", forKey: "gsd.sync.lastServerUpdated")
        defaults.set(2, forKey: "gsd.sync.contractVersion")
        let cursor = SyncCursor(defaults: defaults)
        cursor.clear()
        #expect(cursor.storedVersion() == 2)
        #expect(cursor.needsBackfill())
    }
}
