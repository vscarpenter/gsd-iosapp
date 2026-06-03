import Testing
import Foundation
import GSDSnapshot

struct WidgetSnapshotTests {
    @Test func codableRoundTrip() throws {
        let snap = WidgetSnapshot(
            generatedAt: Date(timeIntervalSince1970: 7),
            tasks: [WidgetTask(id: "x", title: "Title", dueDate: Date(timeIntervalSince1970: 9))],
            totalCount: 5)
        let data = try JSONEncoder().encode(snap)
        let back = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        #expect(back == snap)
    }

    @Test func emptyHasNoTasks() {
        #expect(WidgetSnapshot.empty.tasks.isEmpty)
        #expect(WidgetSnapshot.empty.totalCount == 0)
    }
}
