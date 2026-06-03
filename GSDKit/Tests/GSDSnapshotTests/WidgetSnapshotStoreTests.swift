import Testing
import Foundation
import GSDSnapshot

struct WidgetSnapshotStoreTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var sample: WidgetSnapshot {
        WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 42),
                       tasks: [WidgetTask(id: "a", title: "A", dueDate: nil)], totalCount: 1)
    }

    @Test func roundTrips() throws {
        let store = WidgetSnapshotStore(containerURL: try tempDir())
        try store.write(sample)
        #expect(store.read() == sample)
    }

    @Test func readReturnsNilWhenMissing() throws {
        let store = WidgetSnapshotStore(containerURL: try tempDir())
        #expect(store.read() == nil)
    }

    @Test func readReturnsNilWhenCorrupt() throws {
        let dir = try tempDir()
        let store = WidgetSnapshotStore(containerURL: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent(WidgetSnapshotStore.fileName))
        #expect(store.read() == nil)
    }

    @Test func writeOverwritesPrevious() throws {
        let store = WidgetSnapshotStore(containerURL: try tempDir())
        try store.write(sample)
        let updated = WidgetSnapshot(generatedAt: Date(timeIntervalSince1970: 99), tasks: [], totalCount: 0)
        try store.write(updated)
        #expect(store.read() == updated)
    }

    @Test func writeThrowsWithoutContainer() {
        let store = WidgetSnapshotStore(containerURL: nil)
        #expect(throws: WidgetSnapshotError.self) { try store.write(sample) }
    }
}
