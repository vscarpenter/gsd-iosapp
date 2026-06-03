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
}
