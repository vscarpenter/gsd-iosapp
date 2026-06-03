import Testing
import Foundation
@testable import GSDSync

struct RealtimeEventTests {
    private func decode(_ s: String) -> RealtimeEvent? {
        try? JSONDecoder().decode(RealtimeEvent.self, from: Data(s.utf8))
    }

    @Test func decodesCreateWithRecord() {
        let e = decode(#"{"action":"create","record":{"task_id":"t1","title":"Hi","client_updated_at":"2024-01-01T00:00:00.000Z"}}"#)
        #expect(e?.action == .create)
        #expect(e?.record?.taskId == "t1")
    }

    @Test func decodesDeleteWithoutTaskIdAsNilRecord() {
        // some delete payloads carry only the PB record id, no task_id → record decodes to nil
        let e = decode(#"{"action":"delete","record":{"id":"rec1","collectionName":"tasks"}}"#)
        #expect(e?.action == .delete)
        #expect(e?.record == nil)
    }

    @Test func unknownActionFailsToDecode() {
        #expect(decode(#"{"action":"frobnicate","record":{"task_id":"t1"}}"#) == nil)
    }

    // Real envelopes captured live from api.vinny.io (Probe P1, 2026-06-03). `record` first, `action`
    // last; the DELETE event carries the FULL record incl. task_id (so realtime deletes apply directly).
    @Test func decodesLiveCreateEnvelope() {
        let e = decode(#"{"record":{"client_created_at":"2026-06-03T12:45:04.000Z","client_updated_at":"2026-06-03T12:45:04.000Z","collectionId":"pbc_2602490748","collectionName":"tasks","completed":false,"completed_at":"","dependencies":[],"description":"","device_id":"probe-device","due_date":"","estimated_minutes":0,"id":"hardvg0cdtx46fu","important":false,"last_notification_at":"","notification_enabled":true,"notification_sent":false,"notify_before":0,"owner":"v5eazy6qjtii642","quadrant":"not-urgent-not-important","recurrence":"none","snoozed_until":"","subtasks":[],"tags":[],"task_id":"zzz-5d-probe","time_entries":[],"time_spent":0,"title":"ZZZ 5d SSE probe","urgent":false},"action":"create"}"#)
        #expect(e?.action == .create)
        #expect(e?.record?.taskId == "zzz-5d-probe")
        #expect(e?.record?.deviceId == "probe-device")
    }

    @Test func decodesLiveDeleteEnvelopeWithTaskId() {
        let e = decode(#"{"record":{"collectionId":"pbc_2602490748","collectionName":"tasks","device_id":"probe-device","id":"hardvg0cdtx46fu","owner":"v5eazy6qjtii642","task_id":"zzz-5d-probe","title":"ZZZ 5d SSE probe"},"action":"delete"}"#)
        #expect(e?.action == .delete)
        #expect(e?.record?.taskId == "zzz-5d-probe")   // delete carries task_id → applies directly
    }
}
