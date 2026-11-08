import Testing
import Foundation
import GSDModel
import GSDSnapshot

struct WatchOutboxTests {
    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("WatchOutboxTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func command(_ id: String, at seconds: TimeInterval = 0) -> WatchCommand {
        WatchCommand(id: id, issuedAt: Date(timeIntervalSince1970: seconds), kind: .complete(taskID: "t-\(id)"))
    }

    @Test func startsEmptyWhenNothingWasSaved() {
        #expect(WatchOutbox(directoryURL: directory()).commands.isEmpty)
    }

    @Test func keepsCommandsInTheOrderTheyWereAdded() throws {
        var outbox = WatchOutbox(directoryURL: directory())
        try outbox.add(command("a")); try outbox.add(command("b"))
        #expect(outbox.commands.map(\.id) == ["a", "b"])
    }

    @Test func survivesANewInstanceOnTheSameDirectory() throws {
        let dir = directory()
        var first = WatchOutbox(directoryURL: dir)
        try first.add(command("a"))
        #expect(WatchOutbox(directoryURL: dir).commands.map(\.id) == ["a"])
    }

    @Test func removingACommandLeavesTheOthers() throws {
        var outbox = WatchOutbox(directoryURL: directory())
        try outbox.add(command("a")); try outbox.add(command("b"))
        try outbox.remove(id: "a")
        #expect(outbox.commands.map(\.id) == ["b"])
    }

    @Test func dropsCommandsTheiPhoneHasAcknowledged() throws {
        var outbox = WatchOutbox(directoryURL: directory())
        try outbox.add(command("a")); try outbox.add(command("b")); try outbox.add(command("c"))
        try outbox.drop(acknowledged: ["a", "c", "zzz"])
        #expect(outbox.commands.map(\.id) == ["b"])
    }

    @Test func aCorruptFileReadsAsEmpty() throws {
        let dir = directory()
        try Data("not json".utf8).write(to: dir.appendingPathComponent(WatchOutbox.fileName))
        #expect(WatchOutbox(directoryURL: dir).commands.isEmpty)
    }
}

struct WatchSnapshotStoreTests {
    @Test func roundTripsASnapshot() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WatchSnapshotStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WatchSnapshotStore(directoryURL: dir)
        #expect(store.read() == nil)
        let snap = WatchSnapshot(generatedAt: Date(timeIntervalSince1970: 100), escalationWindowDays: 2,
                                 tasks: [], doFirstTotal: 3, appliedCommandIDs: ["x"])
        try store.write(snap)
        #expect(store.read() == snap)
    }

    @Test func aMissingDirectoryReadsAsNilAndThrowsOnWrite() {
        let store = WatchSnapshotStore(directoryURL: nil)
        #expect(store.read() == nil)
        #expect(throws: (any Error).self) { try store.write(.empty) }
    }
}
