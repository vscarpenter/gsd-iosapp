import Testing
import Foundation
import GSDSnapshot

struct WatchAppliedLedgerTests {
    private func defaults() -> UserDefaults {
        let name = "WatchAppliedLedgerTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func remembersARecordedID() {
        var ledger = WatchAppliedLedger(defaults: defaults())
        #expect(!ledger.contains("a"))
        ledger.record("a")
        #expect(ledger.contains("a"))
    }

    @Test func survivesANewInstanceOnTheSameDefaults() {
        let d = defaults()
        var first = WatchAppliedLedger(defaults: d)
        first.record("a")
        #expect(WatchAppliedLedger(defaults: d).contains("a"))
    }

    @Test func keepsOnlyTheNewestFifty() {
        var ledger = WatchAppliedLedger(defaults: defaults())
        for i in 0..<60 { ledger.record("id-\(i)") }
        #expect(ledger.ids.count == WatchSnapshot.appliedCommandCap)
        #expect(!ledger.contains("id-9"))
        #expect(ledger.contains("id-10"))
        #expect(ledger.ids.last == "id-59")
    }

    @Test func recordingTwiceKeepsOneCopy() {
        var ledger = WatchAppliedLedger(defaults: defaults())
        ledger.record("a"); ledger.record("a")
        #expect(ledger.ids == ["a"])
    }
}
