import Foundation
import Testing
import GSDModel
@testable import GSDWire

/// Top three on the wire (spec section 5): `focus_date` is text and `focus_rank` a number, with `""`
/// and `0` for unset. The pure conversions are corpus-pinned in `TopThree`; these pin the mapper.
struct TopThreeWireTests {
    private let stamp = WireDate.parse("2026-11-07T15:00:00.000Z")!

    private func task(focusDate: String? = nil, focusRank: Int? = nil) -> Task {
        Task(id: "pick", title: "File the receipts", urgent: true, important: true,
             createdAt: stamp, updatedAt: stamp, focusDate: focusDate, focusRank: focusRank)
    }

    private func body(_ wire: PocketBaseTaskRecord) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(wire)) as? [String: Any])
    }

    private func record(_ fields: String) throws -> PocketBaseTaskRecord {
        try JSONDecoder().decode(PocketBaseTaskRecord.self, from: Data(#"{"task_id":"pick"\#(fields)}"#.utf8))
    }

    @Test func aPickGoesOutAsTextAndANumber() throws {
        let sent = try body(TaskWireMapper.toWire(task(focusDate: "2026-11-07", focusRank: 2), owner: "u", deviceId: "ios", defaultReminder: 15))
        #expect(sent["focus_date"] as? String == "2026-11-07")
        #expect(sent["focus_rank"] as? Int == 2)
    }

    @Test func noPickGoesOutAsEmptyAndZero() throws {
        let sent = try body(TaskWireMapper.toWire(task(), owner: "u", deviceId: "ios", defaultReminder: 15))
        #expect(sent["focus_date"] as? String == "")
        #expect(sent["focus_rank"] as? Int == 0)
    }

    @Test func aPulledPickLandsOnANewTaskAndOnAMerge() throws {
        let wire = try record(#","focus_date":"2026-11-07","focus_rank":3"#)
        #expect(TaskWireMapper.toDomain(wire, mergingInto: nil).focusRank == 3)
        let merged = TaskWireMapper.toDomain(wire, mergingInto: task(focusDate: "2026-11-06", focusRank: 1))
        #expect(merged.focusDate == "2026-11-07" && merged.focusRank == 3)
    }

    @Test(arguments: [
        "",                                                  // a record from before the fields
        #","focus_date":"","focus_rank":0"#,                  // unset
        #","focus_date":"2026-11-07","focus_rank":2.5"#,      // a fractional rank
        #","focus_date":"2026-02-30","focus_rank":1"#,        // not a real date
        ##","focus_date":"2026-11-07","focus_rank":"one""##,  // the wrong type
    ])
    func aMissingOrBadPickPullsAsUnsetAndKeepsTheTask(fields: String) throws {
        let pulled = TaskWireMapper.toDomain(try record(fields), mergingInto: task(focusDate: "2026-11-07", focusRank: 1))
        #expect(pulled.id == "pick")
        #expect(pulled.focusDate == nil && pulled.focusRank == nil)
    }

    @Test func pushTakesThePickFromTheCurrentRowNotThePayload() throws {
        let sent = try body(TaskWireMapper.toWire(task(), current: task(focusDate: "2026-11-07", focusRank: 1),
                                                  owner: "u", deviceId: "ios", defaultReminder: 15))
        #expect(sent["focus_date"] as? String == "2026-11-07")
        #expect(sent["focus_rank"] as? Int == 1)
    }

    @Test func pushLeavesBothKeysOffWhenTheRowIsGone() throws {
        let sent = try body(TaskWireMapper.toWire(task(focusDate: "2026-11-07", focusRank: 1), current: nil,
                                                  owner: "u", deviceId: "ios", defaultReminder: 15))
        #expect(!sent.keys.contains("focus_date") && !sent.keys.contains("focus_rank"))
    }
}
