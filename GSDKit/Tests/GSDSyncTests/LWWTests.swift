import Testing
import Foundation
@testable import GSDSync
@testable import GSDWire

struct LWWTests {
    private let t0 = Date(timeIntervalSince1970: 1000.000)
    private let t1 = Date(timeIntervalSince1970: 1000.500)   // +500 ms

    @Test func remoteNewerTakesRemote() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: t1) == .takeRemote)
    }

    @Test func localNewerKeepsLocal() {
        #expect(LWW.resolve(localUpdatedAt: t1, remoteClientUpdatedAt: t0) == .keepLocal)
    }

    @Test func equalMillisecondsIsNoOp() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: t0) == .noOp)
    }

    @Test func unparseableRemoteIsNoOp() {
        #expect(LWW.resolve(localUpdatedAt: t0, remoteClientUpdatedAt: nil) == .noOp)
    }

    @Test func noLocalTakesRemote() {
        #expect(LWW.resolve(localUpdatedAt: nil, remoteClientUpdatedAt: t0) == .takeRemote)
    }

    @Test func subMillisecondDifferenceInSameBucketIsNoOp() {
        let a = Date(timeIntervalSince1970: 1000.5000)
        let b = Date(timeIntervalSince1970: 1000.5004)   // same ms bucket
        #expect(LWW.resolve(localUpdatedAt: a, remoteClientUpdatedAt: b) == .noOp)
    }

    // MARK: Far-future stamps (B-44, web MAX_CLIENT_CLOCK_SKEW_MS)

    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let ceiling = Date(timeIntervalSince1970: 2_000_000_300)     // now + 5 minutes
    private let pastCeiling = Date(timeIntervalSince1970: 2_000_000_300.001)

    @Test func cappedLeavesAStampAtTheCeilingAlone() {
        #expect(LWW.capped(ceiling, now: now) == ceiling)
    }

    @Test func cappedBringsAStampPastTheCeilingDownToIt() {
        #expect(LWW.capped(pastCeiling, now: now) == ceiling)
    }

    @Test func aStampAtTheCeilingCanBeNewer() {
        #expect(LWW.isRemoteNewer(ceiling, than: now, now: now))
    }

    @Test func aStampPastTheCeilingIsNeverNewer() {
        #expect(!LWW.isRemoteNewer(pastCeiling, than: now, now: now))
    }

    @Test func anOlderOrEqualStampIsNotNewer() {
        #expect(!LWW.isRemoteNewer(t0, than: t1, now: now))
        #expect(!LWW.isRemoteNewer(t0, than: t0, now: now))
    }
}
