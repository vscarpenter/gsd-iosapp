import Foundation

/// One PocketBase realtime message (§7.6): `{action, record}`. The `record` decodes leniently via
/// `PocketBaseTaskRecord` (only `task_id` required) — a delete payload that carries only the PB
/// record id yields a `nil` record, and `applyRealtime` falls back to the cadence reconcile.
struct RealtimeEvent: Decodable {
    enum Action: String, Decodable { case create, update, delete }
    let action: Action
    let record: PocketBaseTaskRecord?

    enum CodingKeys: String, CodingKey { case action, record }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(Action.self, forKey: .action)
        record = try? c.decode(PocketBaseTaskRecord.self, forKey: .record)
    }
}
