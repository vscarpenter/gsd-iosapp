import Foundation
import GSDModel

/// A queued local mutation awaiting push to PocketBase (§7.5). Persisted in the `syncQueue` table;
/// the 5c push engine drains the `.pending` items. `payload` is the full task for create/update,
/// nil for delete. Built in 5a; enqueue-on-mutation wiring lands in 5c.
public struct SyncQueueItem: Sendable, Identifiable, Equatable {
    public enum Operation: String, Codable, Sendable { case create, update, delete }
    public enum Status: String, Codable, Sendable { case pending, failed }

    public var id: String
    public var taskId: String
    public var operation: Operation
    public var timestamp: Int          // ms when queued
    public var retryCount: Int
    public var payload: Task?          // full task for create/update; nil for delete
    public var status: Status
    public var lastError: String?
    public var lastAttemptAt: Int?     // ms
    public var failedAt: Int?          // ms

    public init(id: String, taskId: String, operation: Operation, timestamp: Int,
                retryCount: Int = 0, payload: Task? = nil, status: Status = .pending,
                lastError: String? = nil, lastAttemptAt: Int? = nil, failedAt: Int? = nil) {
        self.id = id; self.taskId = taskId; self.operation = operation; self.timestamp = timestamp
        self.retryCount = retryCount; self.payload = payload; self.status = status
        self.lastError = lastError; self.lastAttemptAt = lastAttemptAt; self.failedAt = failedAt
    }
}
