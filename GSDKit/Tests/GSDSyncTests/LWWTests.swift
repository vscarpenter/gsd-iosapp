import Testing
import Foundation
@testable import GSDSync

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
}
