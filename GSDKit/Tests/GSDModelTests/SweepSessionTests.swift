import Testing
import Foundation
@testable import GSDModel

/// The sweep session (spec-weekly-sweep section 4): cards fixed at open, a re-check before each,
/// Skip and Done always available, and an end that only a finished sweep stamps.
struct SweepSessionTests {
    private func cards(_ ids: String...) -> [WeeklySweep.Card] { ids.map { WeeklySweep.Card(id: $0, reason: .stale) } }

    @Test func positionReadsAsThreeOfTwelveAndNothingMore() {
        var s = SweepSession(cards: (1...12).map { WeeklySweep.Card(id: "t\($0)", reason: .stale) })
        #expect(s.position == "1 of 12")
        s.advance(); s.advance()
        #expect(s.position == "3 of 12")
    }

    @Test func advancingPastTheLastCardFinishes() {
        var s = SweepSession(cards: cards("a", "b"))
        #expect(!s.isFinished)
        s.advance(); s.advance()
        #expect(s.isFinished)
        #expect(s.current == nil)
        #expect(s.position == nil)
    }

    @Test func noCardsEndsAtOnce() {
        let s = SweepSession(cards: [])
        #expect(s.isFinished)
        #expect(s.reachedEnd == false)   // nothing was swept, so nothing is stamped
    }

    @Test func reachingTheEndByAdvancingCountsAsFinished() {
        var s = SweepSession(cards: cards("a"))
        s.advance()
        #expect(s.reachedEnd)
    }

    @Test func aCardWhoseTaskNoLongerQualifiesIsSkippedSilently() {
        var s = SweepSession(cards: cards("a", "b", "c"))
        s.settle(qualifying: ["a", "c"])   // b was completed on another device
        #expect(s.current?.id == "a")
        s.advance()
        s.settle(qualifying: ["a", "c"])
        #expect(s.current?.id == "c")      // b never appears
        #expect(s.position == "3 of 3")
    }

    @Test func settlingPastEveryRemainingCardFinishes() {
        var s = SweepSession(cards: cards("a", "b"))
        s.advance()
        s.settle(qualifying: [])
        #expect(s.isFinished)
    }

    @Test func aTaskThatGoesBackToItsOldStateDoesNotRejoinTheSession() {
        // Undo puts the task back where it was; next week's sweep can ask again (spec section 4.3).
        var s = SweepSession(cards: cards("a", "b"))
        s.advance()
        s.settle(qualifying: ["a", "b"])   // a qualifies again after Undo
        #expect(s.current?.id == "b")
    }

    @Test func theEndOffersTopThreeOnlyWhileTodayHasAFreeSlot() {
        #expect(SweepSession.offersTopThree(freeSlot: true, topThreeShipped: true))
        #expect(!SweepSession.offersTopThree(freeSlot: false, topThreeShipped: true))   // a full day ends on its own line
        #expect(!SweepSession.offersTopThree(freeSlot: true, topThreeShipped: false))
    }
}
