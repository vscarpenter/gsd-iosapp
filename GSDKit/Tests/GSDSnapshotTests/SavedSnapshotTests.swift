import Foundation
import Testing
import GSDModel
@testable import GSDSnapshot

struct SavedSnapshotTests {
    @Test func savedItemsStayOutOfTodaysFocus() {
        let now = Date(timeIntervalSince1970: 1_793_016_000)
        let saved = Task(id: "saved", title: "Read later", urgent: true, important: true,
                         createdAt: now, updatedAt: now, dueDate: now, savedAt: now)
        let snapshot = WidgetSnapshotBuilder.todaysFocus(from: [saved], now: now)
        #expect(snapshot.tasks.isEmpty)
        #expect(snapshot.totalCount == 0)
    }
}
