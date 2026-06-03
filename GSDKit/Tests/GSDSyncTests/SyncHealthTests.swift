import Testing
import Foundation
@testable import GSDSync

struct SyncHealthTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func okWhenCleanAndOnline() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 0, tokenExpiry: now.addingTimeInterval(3600),
                                    online: true, now: now)
        #expect(h.level == .ok)
        #expect(h.message == nil)
    }

    @Test func warnsWhenOffline() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 0, tokenExpiry: nil, online: false, now: now)
        #expect(h.level == .warning)
        #expect(h.message != nil)
    }

    @Test func warnsOnFailedItems() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 3, tokenExpiry: now.addingTimeInterval(3600),
                                    online: true, now: now)
        #expect(h.level == .warning)
        #expect(h.message?.contains("3") == true)
    }

    @Test func warnsOnStalePending() {
        // oldest pending 2h ago (> 1h threshold)
        let twoHoursAgoMs = Int((now.addingTimeInterval(-7200)).timeIntervalSince1970 * 1000)
        let h = SyncHealth.evaluate(oldestPendingMs: twoHoursAgoMs, failedCount: 0,
                                    tokenExpiry: now.addingTimeInterval(3600), online: true, now: now)
        #expect(h.level == .warning)
    }

    @Test func okWhenPendingButFresh() {
        let fiveMinAgoMs = Int((now.addingTimeInterval(-300)).timeIntervalSince1970 * 1000)
        let h = SyncHealth.evaluate(oldestPendingMs: fiveMinAgoMs, failedCount: 0,
                                    tokenExpiry: now.addingTimeInterval(3600), online: true, now: now)
        #expect(h.level == .ok)
    }

    @Test func warnsWhenTokenExpired() {
        let h = SyncHealth.evaluate(oldestPendingMs: nil, failedCount: 0, tokenExpiry: now.addingTimeInterval(-10),
                                    online: true, now: now)
        #expect(h.level == .warning)
    }
}
