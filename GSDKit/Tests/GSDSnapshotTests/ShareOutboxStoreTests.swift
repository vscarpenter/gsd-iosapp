import Testing
import Foundation
import GSDSnapshot

struct ShareOutboxStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func capture(_ title: String, at t: TimeInterval) -> SharedCapture {
        SharedCapture(title: title, urls: [], urgent: false, important: false,
                      tags: [], capturedAt: Date(timeIntervalSince1970: t))
    }

    @Test func writeThenPendingReturnsCapture() throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        let pending = store.pending()
        #expect(pending.count == 1)
        #expect(pending.first?.capture.title == "a")
    }

    @Test func pendingSortedByCapturedAt() throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("late", at: 200))
        try store.write(capture("early", at: 100))
        #expect(store.pending().map(\.capture.title) == ["early", "late"])
    }

    @Test func removeDeletesOneFile() throws {
        let store = ShareOutboxStore(directoryURL: try tempDir())
        try store.write(capture("a", at: 1))
        try store.write(capture("b", at: 2))
        let first = store.pending()[0]
        store.remove(id: first.id)
        let remaining = store.pending()
        #expect(remaining.count == 1)
        #expect(remaining.first?.capture.title == "b")
    }

    @Test func corruptFileSkippedAndDeleted() throws {
        let dir = try tempDir()
        let store = ShareOutboxStore(directoryURL: dir)
        try store.write(capture("good", at: 1))
        let badURL = dir.appendingPathComponent("share-outbox/zzz.json")
        try Data("not json".utf8).write(to: badURL)
        let pending = store.pending()
        #expect(pending.map(\.capture.title) == ["good"])     // corrupt skipped
        #expect(!FileManager.default.fileExists(atPath: badURL.path))  // and deleted
    }

    @Test func writeThrowsWithoutContainer() {
        let store = ShareOutboxStore(directoryURL: nil)
        #expect(throws: ShareOutboxError.self) {
            try store.write(SharedCapture(title: "x", urls: [], urgent: false,
                                          important: false, tags: [], capturedAt: Date()))
        }
    }

    @Test func pendingReturnsEmptyWithoutContainer() {
        #expect(ShareOutboxStore(directoryURL: nil).pending().isEmpty)
    }
}
