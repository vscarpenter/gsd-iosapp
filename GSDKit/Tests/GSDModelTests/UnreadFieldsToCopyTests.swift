import Testing
import Foundation
@testable import GSDModel

/// The field-copy decision shared by `pullMerge` and the sync backfill.
struct UnreadFieldsToCopyTests {
    private let t = Date(timeIntervalSince1970: 1_780_000_000)
    private func row(focus: Bool = false, saved: Bool = false) -> TopThree.SyncRow {
        TopThree.SyncRow(updatedAt: t, focusDate: focus ? "2026-11-04" : nil, focusRank: focus ? 2 : nil,
                         savedAt: saved ? t : nil)
    }

    @Test func aBuildOlderThanFocusCopiesAPickItNeverRead() {
        let r = TopThree.unreadFieldsToCopy(storedContract: 3, local: row(), remote: row(focus: true))
        #expect(r == TopThree.UnreadFields(focus: true, savedAt: false))
    }

    @Test func aBuildAtContractFourCopiesNothing() {
        let r = TopThree.unreadFieldsToCopy(storedContract: 4, local: row(), remote: row(focus: true, saved: true))
        #expect(!r.any)
    }

    @Test func aNullSavedAtAtContractThreeIsARealReturn() {
        let r = TopThree.unreadFieldsToCopy(storedContract: 3, local: row(), remote: row(saved: true))
        #expect(!r.savedAt)
    }

    @Test func aMissingVersionCountsAsBelowEveryField() {
        let r = TopThree.unreadFieldsToCopy(storedContract: nil, local: row(), remote: row(focus: true, saved: true))
        #expect(r == TopThree.UnreadFields(focus: true, savedAt: true))
    }

    @Test func aLocalValueIsNeverOverwritten() {
        let r = TopThree.unreadFieldsToCopy(storedContract: 2, local: row(focus: true, saved: true),
                                            remote: row(focus: true, saved: true))
        #expect(!r.any)
    }
}
