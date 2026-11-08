import Testing
import Foundation
@testable import GSDStore

/// The resume and suspend rule shared by background work that touches the store (watch
/// commands). A suspended database rejects every read and write, and suspending one the user
/// has just opened would lock out the live UI.
@MainActor
struct BackgroundDatabaseWindowTests {
    final class Calls { var log: [String] = [] }

    private func window(_ calls: Calls, backgrounded: [Bool]) -> BackgroundDatabaseWindow {
        var answers = backgrounded
        return BackgroundDatabaseWindow(
            isBackgrounded: { answers.isEmpty ? false : answers.removeFirst() },
            resume: { calls.log.append("resume") },
            suspend: { calls.log.append("suspend") })
    }

    @Test func backgroundedRunResumesThenSuspends() async throws {
        let calls = Calls()
        // Entry check, then the exit check: still backgrounded.
        let result = try await window(calls, backgrounded: [true, true]).run { calls.log.append("work"); return 7 }
        #expect(result == 7)
        #expect(calls.log == ["resume", "work", "suspend"])
    }

    @Test func foregroundRunTouchesNothing() async throws {
        let calls = Calls()
        try await window(calls, backgrounded: [false, false]).run { calls.log.append("work") }
        #expect(calls.log == ["work"])
    }

    @Test func appComingForwardDuringTheRunIsNotSuspended() async throws {
        let calls = Calls()
        try await window(calls, backgrounded: [true, false]).run { calls.log.append("work") }
        #expect(calls.log == ["resume", "work"])
    }

    @Test func aThrowingBodyStillSuspends() async {
        struct Boom: Error {}
        let calls = Calls()
        await #expect(throws: Boom.self) {
            try await window(calls, backgrounded: [true, true]).run { throw Boom() }
        }
        #expect(calls.log == ["resume", "suspend"])
    }
}
