import Testing
import Foundation
import GSDModel
import GSDSnapshot

@MainActor
struct ShareInboxTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func capture(_ title: String, at t: TimeInterval) -> SharedCapture {
        SharedCapture(title: title, urls: [], urgent: false, important: false,
                      tags: [], capturedAt: Date(timeIntervalSince1970: t))
    }

    @Test func successfulCreateRemovesFile() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)
        var created: [String] = []
        await inbox.drain(create: { task in created.append(task.title) }, ingestPushed: { _ in })
        #expect(created == ["a"])
        #expect(store.pending().isEmpty)        // file removed after success
    }

    @Test func transientFailureKeepsFile() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)
        struct Boom: Error {}
        await inbox.drain(create: { _ in throw Boom() }, ingestPushed: { _ in })
        #expect(store.pending().count == 1)     // kept for retry
    }

    @Test func processesAllPendingInOrder() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("late", at: 200))
        try store.write(capture("early", at: 100))
        let inbox = ShareInbox(store: store)
        var created: [String] = []
        await inbox.drain(create: { task in created.append(task.title) }, ingestPushed: { _ in })
        #expect(created == ["early", "late"])
        #expect(store.pending().isEmpty)
    }

    /// Single-flight: gate the first drain's `create` on a continuation so it is mid-flight;
    /// start a SECOND drain while it is suspended — that one must hit `guard !isDraining` and
    /// return without creating; then resume the first. Exactly one create must happen.
    @Test func singleFlightPreventsDoubleCreate() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)

        var createCount = 0
        var gate: CheckedContinuation<Void, Never>?
        let gateReady = AsyncStream<Void>.makeStream()

        // First drain: suspends inside `create` until we resume the gate.
        let first = _Concurrency.Task { @MainActor in
            await inbox.drain(create: { _ in
                createCount += 1
                gateReady.continuation.yield()       // signal: we are now mid-create
                await withCheckedContinuation { gate = $0 }
            }, ingestPushed: { _ in })
        }

        // Wait until the first drain is provably mid-create.
        var it = gateReady.stream.makeAsyncIterator()
        _ = await it.next()

        // Second drain while the first is suspended → must no-op (single-flight).
        await inbox.drain(create: { _ in createCount += 1 }, ingestPushed: { _ in })
        #expect(createCount == 1)                    // the overlapping drain did nothing

        gate?.resume()                               // let the first drain finish
        await first.value
        #expect(createCount == 1)                    // still exactly one
        #expect(store.pending().isEmpty)             // and the file is now removed
    }

    // MARK: Captures the extension already pushed to PocketBase

    private func pushedCapture(_ title: String, taskID: String, recordID: String, at t: TimeInterval) -> SharedCapture {
        var c = capture(title, at: t)
        c.taskID = taskID
        c.remoteRecordID = recordID
        return c
    }

    @Test func pushedCaptureGoesToIngestPushedNotCreate() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(pushedCapture("a", taskID: "t-1", recordID: "rec_1", at: 1))
        let inbox = ShareInbox(store: store)
        var created: [String] = []
        var ingested: [String] = []
        await inbox.drain(create: { created.append($0.id) }, ingestPushed: { ingested.append($0.id) })
        #expect(created.isEmpty)
        #expect(ingested == ["t-1"])               // same id the extension pushed under
        #expect(store.pending().isEmpty)
    }

    @Test func pushedCaptureRebuildsTheExactTaskThatWasPushed() async throws {
        // The extension built the task with `now == capturedAt`; the app must land the same
        // timestamps locally so LWW never sees the local copy as newer than the server's.
        let store = ShareOutboxStore(directoryURL: try tempDir())
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try store.write(pushedCapture("a", taskID: "t-1", recordID: "rec_1", at: when.timeIntervalSince1970))
        let inbox = ShareInbox(store: store, now: { Date(timeIntervalSince1970: 9_999_999_999) })
        var landed: Task?
        await inbox.drain(create: { _ in }, ingestPushed: { landed = $0 })
        #expect(landed?.createdAt == when && landed?.updatedAt == when)
    }

    @Test func unpushedCaptureWithTaskIDCreatesUnderThatID() async throws {
        // Push timed out but may have landed: the create must reuse the id so the queued push
        // resolves to an update of the server copy instead of a duplicate.
        let store = ShareOutboxStore(directoryURL: try tempDir())
        var c = capture("a", at: 1)
        c.taskID = "t-1"
        try store.write(c)
        let inbox = ShareInbox(store: store, newID: { "fresh" })
        var created: [String] = []
        await inbox.drain(create: { created.append($0.id) }, ingestPushed: { _ in })
        #expect(created == ["t-1"])
    }

    @Test func legacyCaptureStillGetsAFreshID() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store, newID: { "fresh" })
        var created: [String] = []
        await inbox.drain(create: { created.append($0.id) }, ingestPushed: { _ in })
        #expect(created == ["fresh"])
    }

    @Test func failedIngestKeepsFileForRetry() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(pushedCapture("a", taskID: "t-1", recordID: "rec_1", at: 1))
        let inbox = ShareInbox(store: store)
        struct Boom: Error {}
        await inbox.drain(create: { _ in }, ingestPushed: { _ in throw Boom() })
        #expect(store.pending().count == 1)
    }
}
