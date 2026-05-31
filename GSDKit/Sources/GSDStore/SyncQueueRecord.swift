import Foundation
import GRDB
import GSDModel

/// GRDB row for a `SyncQueueItem` (§7.5). `payload` is the JSON-encoded `Task` (nil for delete),
/// stored as a nullable JSON string via `GSDJSON` (matching the embedded-collection convention in
/// `TaskRecord`). `operation`/`status` persist as their raw strings.
struct SyncQueueRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncQueue"

    var id: String
    var taskId: String
    var operation: String
    var timestamp: Int
    var retryCount: Int
    var payload: String?          // JSON-encoded Task, or NULL for delete
    var status: String
    var lastError: String?
    var lastAttemptAt: Int?
    var failedAt: Int?
}

extension SyncQueueRecord {
    init(_ item: SyncQueueItem) throws {
        id = item.id
        taskId = item.taskId
        operation = item.operation.rawValue
        timestamp = item.timestamp
        retryCount = item.retryCount
        payload = try item.payload.map { try GSDJSON.string($0) }
        status = item.status.rawValue
        lastError = item.lastError
        lastAttemptAt = item.lastAttemptAt
        failedAt = item.failedAt
    }

    func toDomain() throws -> SyncQueueItem {
        SyncQueueItem(
            id: id,
            taskId: taskId,
            // .update / .pending fallbacks: a future/unknown raw value degrades gracefully rather
            // than failing the whole fetch (mirrors TaskRecord's recurrence `.none` defensiveness).
            operation: SyncQueueItem.Operation(rawValue: operation) ?? .update,
            timestamp: timestamp,
            retryCount: retryCount,
            payload: try payload.map { try GSDJSON.value(Task.self, $0) },
            status: SyncQueueItem.Status(rawValue: status) ?? .pending,
            lastError: lastError,
            lastAttemptAt: lastAttemptAt,
            failedAt: failedAt
        )
    }
}
