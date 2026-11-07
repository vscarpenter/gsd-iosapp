import Testing
import Foundation
@testable import GSDModel

/// T12: the carry-over label by how far back the pick is.
struct CarryOverLabelTests {
    private let zone = TimeZone(identifier: "America/Chicago")!
    private func label(_ from: String, today: String = "2026-11-09") -> String? {
        TopThree.carryOverLabel(from: from, today: today, timeZone: zone)
    }

    @Test func oneDayBackIsYesterday() { #expect(label("2026-11-08") == "From yesterday") }

    @Test func twoToSixDaysBackNamesTheWeekday() {
        #expect(label("2026-11-06") == "From Friday")      // Monday the 9th, three days back
        #expect(label("2026-11-03") == "From Tuesday")     // six days back
    }

    @Test func sevenDaysBackIsAWeekAgoBecauseTheWeekdayWouldMatchToday() {
        #expect(label("2026-11-02") == "From a week ago")  // a Monday, and today is a Monday
    }

    @Test func aDateThatDoesntParseHasNoLabel() {
        #expect(label("not a date") == nil)   // carryOver never offers one, and there is no "From earlier"
    }
}
