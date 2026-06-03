import Foundation

extension PocketBaseClient {
    /// Bulk remote index for push (§7.5): `task_id → (recordId, client_updated_at)`. One fetch per push.
    func remoteIndex(token: String) async throws -> [String: (recordId: String, clientUpdatedAt: Date?)] {
        let records = try await listTasks(updatedSince: "1970-01-01T00:00:00.000Z", token: token)
        var index: [String: (recordId: String, clientUpdatedAt: Date?)] = [:]
        for r in records { index[r.taskId] = (r.id, WireDate.parse(r.clientUpdatedAt)) }
        return index
    }

    /// Create a `tasks` record; returns the new PocketBase record id.
    func createTask(_ record: PocketBaseTaskRecord, token: String) async throws -> String {
        let req = authedRequest(path: "/api/collections/tasks/records", method: "POST",
                                token: token, body: try JSONEncoder().encode(record))
        return try await send(req, as: PocketBaseTaskRecord.self).id
    }
    /// Update by record id (PATCH).
    func updateTask(recordId: String, record: PocketBaseTaskRecord, token: String) async throws {
        let req = authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "PATCH",
                                token: token, body: try JSONEncoder().encode(record))
        _ = try await send(req, as: PocketBaseTaskRecord.self)
    }
    /// Delete by record id (204, no body).
    func deleteTask(recordId: String, token: String) async throws {
        try await sendNoContent(authedRequest(path: "/api/collections/tasks/records/\(recordId)", method: "DELETE", token: token))
    }
}
