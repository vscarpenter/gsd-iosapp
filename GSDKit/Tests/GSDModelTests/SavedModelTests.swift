import Foundation
import Testing
@testable import GSDModel

struct SavedModelTests {
    private let now = Date(timeIntervalSince1970: 1_793_016_000)

    private func task() -> Task {
        Task(id: "reading", title: "Read later", description: "Keep this link",
             urgent: false, important: true, createdAt: now, updatedAt: now)
    }

    @Test func legacyTaskDecodesAsActive() throws {
        let encoded = try JSONEncoder().encode(task())
        let decoded = try JSONDecoder().decode(Task.self, from: encoded)
        #expect(decoded.savedAt == nil)
        #expect(!decoded.isSaved)
    }

    @Test func backupPreservesSavedPlacementAndContext() throws {
        var saved = task()
        saved.savedAt = now
        let encoded = try TaskExport.encode(TaskExport(tasks: [saved], exportedAt: now))
        let restored = try TaskExport.decode(encoded)
        #expect(restored.tasks == [saved])
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let row = try #require((json["tasks"] as? [[String: Any]])?.first)
        #expect(row["savedAt"] is String)
        #expect(row["quadrant"] as? String == "not-urgent-important")
    }
}
