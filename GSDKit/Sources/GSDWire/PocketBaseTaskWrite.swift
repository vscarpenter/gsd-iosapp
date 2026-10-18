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

extension PocketBaseClient {
    /// Bulk remote index for push and deletion reconcile (§7.5): `task_id → (recordId,
    /// client_updated_at)`. One fetch per push. Fails closed (parity S10): a record it can't
    /// identify throws, as does a listing that repeats a task (`listAll`), instead of returning an
    /// index that would let reconcile delete a local task the server still holds.
    package func remoteIndex(token: String) async throws -> [String: (recordId: String, clientUpdatedAt: Date?)] {
        let listing = try await listAll(RemoteTaskIdentity.self, updatedSince: "1970-01-01T00:00:00.000Z", token: token)
        if listing.undecodable > 0 {
            throw RemoteListingIncomplete(reason: "\(listing.undecodable) records could not be identified")
        }
        var index: [String: (recordId: String, clientUpdatedAt: Date?)] = [:]
        for r in listing.items { index[r.taskId] = (r.recordId, r.clientUpdatedAt.flatMap(WireDate.parse)) }
        return index
    }

    /// Create a `tasks` record; returns the new PocketBase record id.
    package func createTask(_ record: PocketBaseTaskRecord, token: String) async throws -> String {
        let req = authedRequest(path: "/api/collections/tasks/records", method: "POST",
                                token: token, body: try JSONEncoder().encode(record))
        return try await send(req, as: PocketBaseTaskRecord.self).id
    }
    /// Update by record id (PATCH).
    package func updateTask(recordId: String, record: PocketBaseTaskRecord, token: String) async throws {
        let req = authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "PATCH",
                                token: token, body: try JSONEncoder().encode(record))
        _ = try await send(req, as: PocketBaseTaskRecord.self)
    }
    /// Delete by record id (204, no body).
    package func deleteTask(recordId: String, token: String) async throws {
        try await sendNoContent(authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "DELETE", token: token))
    }
}
