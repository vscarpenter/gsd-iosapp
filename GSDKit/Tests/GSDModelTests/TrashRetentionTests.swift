import Testing
import Foundation
@testable import GSDModel

/// The retention boundary decides when a recoverable task stops being recoverable, so the
/// off-by-one here is the difference between "restored it on day 30" and "it was gone".
struct TrashRetentionTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-08-28T12:00:00Z — deliberately mid-day, so the start-of-day anchor matters.
    private let now = Date(timeIntervalSince1970: 1_787_054_400)

    private func daysBeforeNow(_ days: Double) -> Date {
        now.addingTimeInterval(-days * 86_400)
    }

    @Test func retentionIsThirtyDaysMatchingTheWebClient() {
        #expect(TrashRetention.days == 30)
    }

    @Test func cutoffAnchorsToStartOfDayNotTheCurrentInstant() {
        // Same anchor convention as AutoArchive, so the cutoff is stable across the day
        // rather than sliding forward every second the app is open.
        let cutoff = TrashRetention.cutoff(now: now, calendar: utc)
        #expect(utc.startOfDay(for: cutoff) == cutoff)
        #expect(utc.dateComponents([.day], from: cutoff, to: utc.startOfDay(for: now)).day == 30)
    }

    @Test func aRowDeletedTodayIsKept() {
        #expect(TrashRetention.isExpired(deletedAt: now, now: now, calendar: utc) == false)
    }

    @Test func aRowDeletedTwentyNineDaysAgoIsKept() {
        #expect(TrashRetention.isExpired(deletedAt: daysBeforeNow(29), now: now, calendar: utc) == false)
    }

    @Test func aRowExactlyOnTheCutoffIsKept() {
        // Strictly-before, so the boundary instant itself survives — a user restoring at
        // the last moment gets their task, not a race.
        let cutoff = TrashRetention.cutoff(now: now, calendar: utc)
        #expect(TrashRetention.isExpired(deletedAt: cutoff, now: now, calendar: utc) == false)
    }

    @Test func aRowOneSecondPastTheCutoffIsExpired() {
        let cutoff = TrashRetention.cutoff(now: now, calendar: utc)
        #expect(TrashRetention.isExpired(deletedAt: cutoff.addingTimeInterval(-1),
                                        now: now, calendar: utc) == true)
    }

    @Test func aRowDeletedThirtyOneDaysAgoIsExpired() {
        #expect(TrashRetention.isExpired(deletedAt: daysBeforeNow(31), now: now, calendar: utc) == true)
    }

    @Test func daysRemainingCountsDownFromThirty() {
        #expect(TrashRetention.daysRemaining(deletedAt: now, now: now, calendar: utc) == 30)
        #expect(TrashRetention.daysRemaining(deletedAt: daysBeforeNow(1), now: now, calendar: utc) == 29)
        #expect(TrashRetention.daysRemaining(deletedAt: daysBeforeNow(29.5), now: now, calendar: utc) == 1)
    }

    @Test func daysRemainingNeverGoesNegative() {
        #expect(TrashRetention.daysRemaining(deletedAt: daysBeforeNow(90), now: now, calendar: utc) == 0)
    }
}
