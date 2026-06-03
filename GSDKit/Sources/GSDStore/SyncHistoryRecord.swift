import Foundation
import GRDB

/// GRDB row for `syncHistory` (v5). Mirrors `SyncQueueRecord`'s conformances. Status/triggeredBy
/// persist as their raw strings, defaulting defensively on an unknown value (like `SyncQueueRecord`).
struct SyncHistoryRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "syncHistory"

    var id: String
    var timestamp: Int
    var status: String
    var pushedCount: Int
    var pulledCount: Int
    var conflictsResolved: Int
    var failedCount: Int?
    var errorMessage: String?
    var duration: Int?
    var deviceId: String
    var triggeredBy: String

    init(_ e: SyncHistoryEntry) {
        id = e.id; timestamp = e.timestamp; status = e.status.rawValue
        pushedCount = e.pushedCount; pulledCount = e.pulledCount
        conflictsResolved = e.conflictsResolved; failedCount = e.failedCount
        errorMessage = e.errorMessage; duration = e.duration
        deviceId = e.deviceId; triggeredBy = e.triggeredBy.rawValue
    }

    func toDomain() -> SyncHistoryEntry {
        SyncHistoryEntry(
            id: id, timestamp: timestamp,
            status: SyncHistoryEntry.Status(rawValue: status) ?? .success,
            pushedCount: pushedCount, pulledCount: pulledCount,
            conflictsResolved: conflictsResolved, failedCount: failedCount,
            errorMessage: errorMessage, duration: duration, deviceId: deviceId,
            triggeredBy: SyncHistoryEntry.TriggeredBy(rawValue: triggeredBy) ?? .auto)
    }
}
