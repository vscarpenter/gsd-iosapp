import Foundation
import Testing
import GSDModel
@testable import GSDWire
@testable import GSDSync

struct SavedWireTests {
    private let savedString = "2026-10-26T12:00:00.000Z"

    @Test func webSavedWireSurvivesNewPullMergeAndPush() throws {
        let raw = Data("""
            {"id":"pb-reading","task_id":"reading","owner":"user",
             "title":"Read later","description":"A short note", "important":true,
             "saved_at":"\(savedString)","client_created_at":"\(savedString)",
             "client_updated_at":"\(savedString)"}
            """.utf8)
        let wire = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: raw)
        let task = TaskWireMapper.toDomain(wire, mergingInto: nil)
        #expect(task.savedAt == WireDate.parse(savedString))
        #expect(task.isSaved)
        let merged = TaskWireMapper.toDomain(wire, mergingInto: task)
        let pushed = TaskWireMapper.toWire(merged, owner: "user", deviceId: "ios", defaultReminder: 15)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(pushed)) as? [String: Any])
        #expect(body["saved_at"] as? String == savedString)
        #expect(body["task_id"] as? String == "reading")
    }

    @Test func nativeReturnExplicitlyClearsPlacementOnWeb() throws {
        let stamp = try #require(WireDate.parse(savedString))
        var task = Task(id: "reading", title: "Read later", urgent: false, important: true,
                        createdAt: stamp, updatedAt: stamp, savedAt: stamp)
        task.savedAt = nil
        let wire = TaskWireMapper.toWire(task, owner: "user", deviceId: "ios", defaultReminder: 15)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
        #expect(body["saved_at"] as? String == "")
        #expect(!TaskWireMapper.toDomain(wire, mergingInto: nil).isSaved)
    }

    @Test func webReturnResetsNativeReminderStateWhileSavedEditsPreserveIt() throws {
        let stamp = try #require(WireDate.parse(savedString))
        let local = Task(id: "reading", title: "Read later", urgent: false, important: true,
                         createdAt: stamp, updatedAt: stamp, notificationSent: true,
                         lastNotificationAt: stamp, snoozedUntil: stamp.addingTimeInterval(3600), savedAt: stamp)
        var wire = TaskWireMapper.toWire(local, owner: "user", deviceId: "web", defaultReminder: 15)
        let stillSaved = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(stillSaved.notificationSent && stillSaved.snoozedUntil == local.snoozedUntil)
        wire.savedAt = ""
        let returned = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(!returned.notificationSent)
        #expect(returned.lastNotificationAt == nil && returned.snoozedUntil == nil)
    }

    @Test(arguments: ["{}", "{\"saved_at\":null}", "{\"saved_at\":\"\"}"])
    func legacyEmptyPlacementIsActive(fields: String) throws {
        var json = try #require(JSONSerialization.jsonObject(with: Data(fields.utf8)) as? [String: Any])
        json["task_id"] = "legacy"
        let wire = try JSONDecoder().decode(PocketBaseTaskRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!TaskWireMapper.toDomain(wire, mergingInto: nil).isSaved)
    }

    private func pushBody(_ payload: Task, current: Task?) throws -> [String: Any] {
        let wire = TaskWireMapper.toWire(payload, current: current, owner: "user", deviceId: "ios")
        return try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
    }

    @Test func pushTakesThePlacementFromTheCurrentRowNotThePayload() throws {
        let stamp = try #require(WireDate.parse(savedString))
        let payload = Task(id: "reading", title: "Queued before the backfill", urgent: false, important: true,
                           createdAt: stamp, updatedAt: stamp.addingTimeInterval(60))
        var current = payload
        current.savedAt = stamp
        let body = try pushBody(payload, current: current)
        #expect(body["saved_at"] as? String == savedString)
        #expect(body["title"] as? String == "Queued before the backfill")   // the rest is still the payload
    }

    @Test func pushSendsAnEmptyPlacementForACurrentRowThatIsNotSaved() throws {
        let stamp = try #require(WireDate.parse(savedString))
        var payload = Task(id: "reading", title: "Read later", urgent: false, important: true,
                           createdAt: stamp, updatedAt: stamp, savedAt: stamp)
        var current = payload
        current.savedAt = nil
        payload.title = "Saved, then returned"
        #expect(try pushBody(payload, current: current)["saved_at"] as? String == "")
    }

    @Test func pushLeavesThePlacementOffWhenTheRowIsGone() throws {
        let stamp = try #require(WireDate.parse(savedString))
        let payload = Task(id: "reading", title: "Archived since", urgent: false, important: true,
                           createdAt: stamp, updatedAt: stamp)
        let body = try pushBody(payload, current: nil)
        #expect(!body.keys.contains("saved_at"))
        #expect(body["task_id"] as? String == "reading")
    }
}
