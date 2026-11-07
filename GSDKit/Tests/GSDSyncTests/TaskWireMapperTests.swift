import Testing
import Foundation
import GSDModel
@testable import GSDSync
@testable import GSDWire

struct TaskWireMapperTests {
    private func date(_ s: String) -> Date { WireDate.parse(s)! }

    private func sampleTask(
        timeEntries: [TimeEntry] = [],
        notificationSent: Bool = false,
        lastNotificationAt: Date? = nil,
        snoozedUntil: Date? = nil,
        parentTaskId: String? = nil,
        timeSpent: Int? = nil
    ) -> Task {
        Task(
            id: "task-1", title: "Ship", description: "do it",
            urgent: true, important: false,
            completed: false, completedAt: nil,
            createdAt: date("2026-06-01T10:00:00.000Z"),
            updatedAt: date("2026-06-15T08:30:00.500Z"),
            dueDate: date("2026-06-15T09:00:00.000Z"),
            recurrence: .weekly, tags: ["work"],
            subtasks: [Subtask(id: "s1", title: "design", completed: true)],
            dependencies: ["task-0"], parentTaskId: parentTaskId,
            notifyBefore: 30, notificationEnabled: true,
            notificationSent: notificationSent, lastNotificationAt: lastNotificationAt,
            snoozedUntil: snoozedUntil, estimatedMinutes: 120,
            timeSpent: timeSpent, timeEntries: timeEntries
        )
    }

    // MARK: toWire

    @Test func toWireMapsScalarsAndDerivesQuadrant() {
        let r = TaskWireMapper.toWire(sampleTask(), owner: "user-1", deviceId: "dev-A", recordId: "rec-9")
        #expect(r.id == "rec-9")                             // recordId param
        #expect(r.taskId == "task-1")                        // join key = Task.id
        #expect(r.owner == "user-1")
        #expect(r.deviceId == "dev-A")
        #expect(r.quadrant == Quadrant(urgent: true, important: false).rawValue)  // derived, not stored
        #expect(r.dueDate == "2026-06-15T09:00:00.000Z")
        #expect(r.completedAt == "")                         // nil Date → ""
        #expect(r.clientUpdatedAt == "2026-06-15T08:30:00.500Z")
        #expect(r.timeSpent == 0)                            // nil timeSpent → 0
    }

    @Test func toWireFlattensTimeEntries() {
        let start = date("2026-06-15T08:00:00.000Z")
        let task = sampleTask(timeEntries: [
            TimeEntry(id: "te1", startedAt: start, endedAt: start.addingTimeInterval(95), notes: "x"),
            TimeEntry(id: "te2", startedAt: start, endedAt: nil, notes: nil)   // running
        ])
        let r = TaskWireMapper.toWire(task, owner: "u", deviceId: "d")
        #expect(r.timeEntries == [
            WireTimeEntry(id: "te1", startedAt: "2026-06-15T08:00:00.000Z", minutes: 1),  // floor(95s)
            WireTimeEntry(id: "te2", startedAt: "2026-06-15T08:00:00.000Z", minutes: 0)   // running → 0
        ])
    }

    // MARK: toDomain — reconstruct (no local task)

    @Test func toDomainReconstructsWhenNoLocal() {
        let start = date("2026-06-15T08:00:00.000Z")
        let wire = TaskWireMapper.toWire(
            sampleTask(timeEntries: [TimeEntry(id: "te1", startedAt: start,
                                               endedAt: start.addingTimeInterval(120), notes: "n")]),
            owner: "u", deviceId: "d")
        let task = TaskWireMapper.toDomain(wire, mergingInto: nil)
        #expect(task.id == "task-1")                         // task_id → Task.id
        #expect(task.quadrant == Quadrant(urgent: true, important: false))  // recomputed from flags
        #expect(task.parentTaskId == nil)
        #expect(task.timeEntries.count == 1)
        #expect(task.timeEntries[0].endedAt == start.addingTimeInterval(120))  // synthesized startedAt+minutes
        #expect(task.timeEntries[0].notes == nil)            // documented loss
    }

    // MARK: toDomain — merge (local task exists)

    @Test func toDomainMergePreservesDeviceLocalAndDerivedFields() {
        let localStart = date("2026-06-10T07:00:00.000Z")
        let local = sampleTask(
            timeEntries: [TimeEntry(id: "local-te", startedAt: localStart,
                                    endedAt: localStart.addingTimeInterval(600), notes: "local note")],
            notificationSent: true,
            lastNotificationAt: date("2026-06-14T09:00:00.000Z"),
            snoozedUntil: date("2026-06-16T09:00:00.000Z"),
            parentTaskId: "parent-1",
            timeSpent: 10
        )
        // Remote has DIFFERENT title + its own (would-be) device-local values.
        var wire = TaskWireMapper.toWire(local, owner: "u", deviceId: "remote-dev")
        wire.title = "Remote title"
        wire.notificationSent = false
        wire.lastNotificationAt = ""
        wire.snoozedUntil = ""
        wire.timeSpent = 999
        wire.timeEntries = []   // remote lost the entries

        let merged = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(merged.title == "Remote title")                       // synced field ← remote
        #expect(merged.notificationSent == true)                      // device-local ← local
        #expect(merged.lastNotificationAt == date("2026-06-14T09:00:00.000Z"))
        #expect(merged.snoozedUntil == date("2026-06-16T09:00:00.000Z"))
        #expect(merged.parentTaskId == "parent-1")                    // no wire column → local
        #expect(merged.timeSpent == 10)                               // derived → tracks local entries
        #expect(merged.timeEntries == local.timeEntries)              // prefer-local (lossy wire)
    }

    @Test func mergePreservesLocalNilDeviceLocalFields() {
        // The trap: local exists but its device-local fields are nil — merge must KEEP nil, not pull remote.
        let local = sampleTask(notificationSent: false, lastNotificationAt: nil, snoozedUntil: nil)
        var wire = TaskWireMapper.toWire(local, owner: "u", deviceId: "d")
        wire.lastNotificationAt = "2026-06-14T09:00:00.000Z"          // remote has a value
        wire.snoozedUntil = "2026-06-16T09:00:00.000Z"
        let merged = TaskWireMapper.toDomain(wire, mergingInto: local)
        #expect(merged.lastNotificationAt == nil)                     // local nil preserved, NOT remote
        #expect(merged.snoozedUntil == nil)
    }

    // MARK: toDomain — a pulled due date at a new instant is a new reminder (B-55)

    private func remindedLocal() -> Task {
        sampleTask(notificationSent: true, lastNotificationAt: date("2026-06-15T08:30:00.000Z"),
                   snoozedUntil: date("2026-06-15T10:00:00.000Z"))
    }

    private func expectReminderReset(_ merged: Task) {
        #expect(merged.notificationSent == false)
        #expect(merged.lastNotificationAt == nil)
        #expect(merged.snoozedUntil == nil)
    }

    @Test func aPulledDueDateAtANewInstantResetsThisDevicesReminderState() {
        var wire = TaskWireMapper.toWire(remindedLocal(), owner: "u", deviceId: "web")
        wire.dueDate = "2026-06-16T09:00:00.000Z"
        let merged = TaskWireMapper.toDomain(wire, mergingInto: remindedLocal())
        #expect(merged.dueDate == date("2026-06-16T09:00:00.000Z"))
        expectReminderReset(merged)
    }

    @Test(arguments: [(local: true, remote: false), (local: false, remote: true)])
    func aPulledDueDateAddedOrRemovedResetsThisDevicesReminderState(dated: (local: Bool, remote: Bool)) {
        var local = remindedLocal()
        local.dueDate = dated.local ? date("2026-06-15T09:00:00.000Z") : nil
        var wire = TaskWireMapper.toWire(local, owner: "u", deviceId: "web")
        wire.dueDate = dated.remote ? "2026-06-15T09:00:00.000Z" : ""
        expectReminderReset(TaskWireMapper.toDomain(wire, mergingInto: local))
    }

    @Test(arguments: ["2026-06-15T09:00:00Z", "2026-06-15T04:00:00.000-05:00"])
    func theSameDueInstantInAnotherFormKeepsThisDevicesReminderState(remoteDue: String) {
        var wire = TaskWireMapper.toWire(remindedLocal(), owner: "u", deviceId: "web")
        wire.dueDate = remoteDue
        wire.title = "Renamed on the web"
        let merged = TaskWireMapper.toDomain(wire, mergingInto: remindedLocal())
        #expect(merged.notificationSent == true)
        #expect(merged.lastNotificationAt == date("2026-06-15T08:30:00.000Z"))
        #expect(merged.snoozedUntil == date("2026-06-15T10:00:00.000Z"))
    }

    /// The symptom: the due date moved earlier, and a snooze set for the old date outlived the move.
    /// It ends after the new reminder, so it would win under either snooze rule and skip that reminder.
    @Test func aStaleSnoozeNoLongerBeatsAMovedDueDate() throws {
        var local = remindedLocal()
        local.dueDate = date("2026-06-20T09:00:00.000Z")
        local.snoozedUntil = date("2026-06-19T10:00:00.000Z")
        var wire = TaskWireMapper.toWire(local, owner: "u", deviceId: "web")
        wire.dueDate = "2026-06-16T09:00:00.000Z"
        let merged = TaskWireMapper.toDomain(wire, mergingInto: local)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let fire = ReminderMath.nextFire(for: merged, inputs: .init(masterEnabled: true, defaultReminder: 15),
                                         quietStart: nil, quietEnd: nil,
                                         now: date("2026-06-15T09:30:00.000Z"), calendar: utc)
        #expect(fire == date("2026-06-16T08:30:00.000Z"))              // notifyBefore 30 on the new date
    }

    // MARK: round-trip

    @Test func roundTripPreservesJoinKeyAndDocumentsLoss() {
        let start = date("2026-06-15T08:00:00.000Z")
        let original = sampleTask(timeEntries: [TimeEntry(id: "te1", startedAt: start,
                                                          endedAt: start.addingTimeInterval(125), notes: "keep?")])
        let wire = TaskWireMapper.toWire(original, owner: "u", deviceId: "d", recordId: "rec-1")
        let restored = TaskWireMapper.toDomain(wire, mergingInto: nil)
        #expect(restored.id == original.id)                           // Task.id ↔ task_id preserved
        #expect(wire.id == "rec-1" && wire.id != wire.taskId)         // record id kept distinct from join key
        #expect(restored.title == original.title)
        #expect(restored.timeEntries[0].endedAt == start.addingTimeInterval(120))  // floored to 2 min (loss)
        #expect(restored.timeEntries[0].notes == nil)                 // notes lost (documented)
    }
}
