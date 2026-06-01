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

    @Test func advanceClampsToNowMinus30WhenMaxAppliedIsFuture() throws {
        let cursor = SyncCursor(defaults: freshDefaults())
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1_000_000_100), now: now)
        let isoString = try #require(cursor.load())
        let savedDate = try #require(WireDate.parse(isoString))
        #expect(Int(savedDate.timeIntervalSince1970) == 1_000_000_000 - 30)
    }

    @Test func advanceUsesMaxAppliedMinus30WhenInPast() throws {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 999_999_500), now: Date(timeIntervalSince1970: 1_000_000_000))
        let isoString = try #require(cursor.load())
        let savedDate = try #require(WireDate.parse(isoString))
        #expect(Int(savedDate.timeIntervalSince1970) == 999_999_500 - 30)
    }

    @Test func advanceNoOpWhenMaxAppliedNil() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: nil, now: Date())
        #expect(cursor.load() == nil)
    }

    @Test func clearResetsCursor() {
        let cursor = SyncCursor(defaults: freshDefaults())
        cursor.advance(maxApplied: Date(timeIntervalSince1970: 1000), now: Date(timeIntervalSince1970: 1_000_000))
        cursor.clear()
        #expect(cursor.load() == nil)
    }
}
