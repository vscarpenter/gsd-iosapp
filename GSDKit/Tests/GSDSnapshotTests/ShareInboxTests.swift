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
        await inbox.drain { task in created.append(task.title) }
        #expect(created == ["a"])
        #expect(store.pending().isEmpty)        // file removed after success
    }

    @Test func transientFailureKeepsFile() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let inbox = ShareInbox(store: store)
        struct Boom: Error {}
        await inbox.drain { _ in throw Boom() }
        #expect(store.pending().count == 1)     // kept for retry
    }

    @Test func processesAllPendingInOrder() async throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("late", at: 200))
        try store.write(capture("early", at: 100))
        let inbox = ShareInbox(store: store)
        var created: [String] = []
        await inbox.drain { task in created.append(task.title) }
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
            await inbox.drain { _ in
                createCount += 1
                gateReady.continuation.yield()       // signal: we are now mid-create
                await withCheckedContinuation { gate = $0 }
            }
        }

        // Wait until the first drain is provably mid-create.
        var it = gateReady.stream.makeAsyncIterator()
        _ = await it.next()

        // Second drain while the first is suspended → must no-op (single-flight).
        await inbox.drain { _ in createCount += 1 }
        #expect(createCount == 1)                    // the overlapping drain did nothing

        gate?.resume()                               // let the first drain finish
        await first.value
        #expect(createCount == 1)                    // still exactly one
        #expect(store.pending().isEmpty)             // and the file is now removed
    }
}
