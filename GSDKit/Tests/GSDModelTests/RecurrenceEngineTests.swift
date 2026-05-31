import Testing
import Foundation
@testable import GSDModel

struct RecurrenceEngineTests {
    /// A fixed UTC gregorian calendar so date math is deterministic.
    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = 12
        return cal.date(from: comps)!
    }

    private func ymd(_ date: Date) -> (Int, Int, Int) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    @Test func dailyAdvancesOneDay() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 31), by: .daily, calendar: cal))
        #expect(ymd(next) == (2026, 2, 1))
    }

    @Test func weeklyAdvancesSevenDaysAcrossMonthBoundary() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 28), by: .weekly, calendar: cal))
        #expect(ymd(next) == (2026, 2, 4))
    }

    @Test func monthlyJan31ClampsToFebEndNonLeap() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 1, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2026, 2, 28))
    }

    @Test func monthlyJan31ClampsToFeb29InLeapYear() throws {
        let next = try #require(RecurrenceEngine.advance(date(2024, 1, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2024, 2, 29))
    }

    @Test func monthlyMar31ClampsToApr30() throws {
        let next = try #require(RecurrenceEngine.advance(date(2026, 3, 31), by: .monthly, calendar: cal))
        #expect(ymd(next) == (2026, 4, 30))
    }

    @Test func noneReturnsNil() {
        #expect(RecurrenceEngine.advance(date(2026, 1, 31), by: .none, calendar: cal) == nil)
    }
}
