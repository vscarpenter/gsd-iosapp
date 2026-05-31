import Testing
import Foundation
@testable import GSDModel

struct DueDatePresetsTests {
    /// June 2026: 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat, 7=Sun.
    private func calendar(firstWeekday: Int) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Chicago")!
        c.firstWeekday = firstWeekday
        return c
    }
    private func day(_ d: Int, cal: Calendar) -> Date {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = d; comps.hour = 9
        return cal.date(from: comps)!
    }
    private func ymd(_ date: Date, cal: Calendar) -> (Int, Int, Int) {
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return (c.year!, c.month!, c.day!)
    }

    @Test func noneIsNil() {
        let cal = calendar(firstWeekday: 1)
        #expect(DueDatePresets.resolve(.none, today: day(3, cal: cal), calendar: cal) == nil)
    }

    @Test func todayIsStartOfToday() {
        let cal = calendar(firstWeekday: 1)
        let resolved = DueDatePresets.resolve(.today, today: day(3, cal: cal), calendar: cal)!
        #expect(ymd(resolved, cal: cal) == (2026, 6, 3))
        #expect(resolved == cal.startOfDay(for: day(3, cal: cal)))
    }

    @Test func thisWeekResolvesToFridayOnWeekdays() {
        let cal = calendar(firstWeekday: 1)
        for d in 1...5 { // Mon..Fri
            let resolved = DueDatePresets.resolve(.thisWeek, today: day(d, cal: cal), calendar: cal)!
            #expect(ymd(resolved, cal: cal) == (2026, 6, 5)) // Fri Jun 5
        }
    }

    @Test func thisWeekOnWeekendResolvesToNextFriday() {
        let cal = calendar(firstWeekday: 1)
        for d in [6, 7] { // Sat, Sun
            let resolved = DueDatePresets.resolve(.thisWeek, today: day(d, cal: cal), calendar: cal)!
            #expect(ymd(resolved, cal: cal) == (2026, 6, 12)) // next Fri
        }
    }

    @Test func nextWeekResolvesToMondayStrictlyAfterToday() {
        let cal = calendar(firstWeekday: 1)
        // Mon..Sun all resolve to Mon Jun 8 (Mon→+7; Sun→+1, the upcoming Monday).
        for d in 1...7 {
            let resolved = DueDatePresets.resolve(.nextWeek, today: day(d, cal: cal), calendar: cal)!
            #expect(ymd(resolved, cal: cal) == (2026, 6, 8))
        }
    }

    @Test func presetsAreIndependentOfFirstWeekday() {
        // PROBE-VERIFIED: explicit weekday arithmetic must not depend on locale.
        let sun = calendar(firstWeekday: 1)
        let mon = calendar(firstWeekday: 2)
        for d in 1...7 {
            for preset in [DueDatePreset.thisWeek, .nextWeek] {
                let a = DueDatePresets.resolve(preset, today: day(d, cal: sun), calendar: sun)
                let b = DueDatePresets.resolve(preset, today: day(d, cal: mon), calendar: mon)
                #expect(a == b)
            }
        }
    }
}
