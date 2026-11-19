import Foundation

/// The three fields push and deletion reconcile need from a remote record. Decoded on its own,
/// so a record whose other fields are malformed still counts as present on the server (parity
/// S10). A record missing `id` or `task_id` can't be identified and fails to decode.
struct RemoteTaskIdentity: Decodable, Sendable {
    let recordId: String
    let taskId: String
    /// Raw `client_updated_at`. Missing or a non-string reads as nil, which push treats as an
    /// unusable version rather than a reason to throw out the whole index (parity S11).
    let clientUpdatedAt: String?

    private enum CodingKeys: String, CodingKey {
        case recordId = "id"
        case taskId = "task_id"
        case clientUpdatedAt = "client_updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        recordId = try c.decode(String.self, forKey: .recordId)
        taskId = try c.decode(String.self, forKey: .taskId)
        guard !recordId.isEmpty, !taskId.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .taskId, in: c, debugDescription: "empty id or task_id")
        }
        clientUpdatedAt = try? c.decodeIfPresent(String.self, forKey: .clientUpdatedAt)
    }
}

/// One remote task as push and reconcile see it. `version` is the listing's raw
/// `client_updated_at`, untouched: the server's guarded routes compare it as a string, byte for
/// byte. `clientUpdatedAt` is the parsed form for LWW comparisons.
package struct RemoteIndexEntry: Sendable, Equatable {
    package let recordId: String
    package let version: String?
    package let clientUpdatedAt: Date?

    /// `clientUpdatedAt` is derived from `version`, so the two can't disagree.
    package init(recordId: String, version: String?) {
        self.recordId = recordId
        self.version = version
        self.clientUpdatedAt = version.flatMap(WireDate.parse)
    }
}

extension PocketBaseClient {
    /// Bulk remote index for push and deletion reconcile (§7.5): `task_id → RemoteIndexEntry`. One
    /// fetch per push. Fails closed (parity S10): a record it can't identify throws, as does a listing
    /// that repeats a task (`listAll`), instead of returning an index that would let reconcile delete
    /// a local task the server still holds.
    package func remoteIndex(token: String) async throws -> [String: RemoteIndexEntry] {
        let listing = try await listAll(RemoteTaskIdentity.self, updatedSince: "1970-01-01T00:00:00.000Z", token: token)
        if listing.undecodable > 0 {
            throw RemoteListingIncomplete(reason: "\(listing.undecodable) records could not be identified")
        }
        var index: [String: RemoteIndexEntry] = [:]
        for r in listing.items {
            index[r.taskId] = RemoteIndexEntry(recordId: r.recordId, version: r.clientUpdatedAt)
        }
        return index
    }

    /// Create a `tasks` record; returns the new PocketBase record id.
    package func createTask(_ record: PocketBaseTaskRecord, token: String) async throws -> String {
        let req = authedRequest(path: "/api/collections/tasks/records", method: "POST",
                                token: token, body: try JSONEncoder().encode(record))
        return try await send(req, as: PocketBaseTaskRecord.self).id
    }
    /// Delete by record id (204, no body).
    package func deleteTask(recordId: String, token: String) async throws {
        try await sendNoContent(authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "DELETE", token: token))
    }
    /// Version-checked update through the server's task route (ADR 0021). 204 with no body on success;
    /// 412 when `expectedVersion` no longer matches, 404 when the record is gone or not ours.
    /// `id` is dropped because the route's allow-list rejects it.
    package func updateTaskGuarded(recordId: String, expectedVersion: String,
                                   record: PocketBaseTaskRecord, token: String) async throws {
        let encoded = try JSONEncoder().encode(record)
        guard var data = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw EncodingError.invalidValue(record, .init(codingPath: [], debugDescription: "record is not a JSON object"))
        }
        data.removeValue(forKey: "id")
        let body = try JSONSerialization.data(withJSONObject: ["expected_version": expectedVersion, "data": data])
        try await sendNoContent(authedRequest(path: Self.guardedTaskPath(recordId), method: "PATCH", token: token, body: body))
    }
    /// Version-checked delete through the server's task route (ADR 0021). 204 with no body.
    package func deleteTaskGuarded(recordId: String, expectedVersion: String, token: String) async throws {
        let body = try JSONEncoder().encode(["expected_version": expectedVersion])
        try await sendNoContent(authedRequest(path: Self.guardedTaskPath(recordId), method: "DELETE", token: token, body: body))
    }
    private static func guardedTaskPath(_ recordId: String) -> String {
        "/api/gsd/tasks/" + (recordId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? recordId)
    }
}
