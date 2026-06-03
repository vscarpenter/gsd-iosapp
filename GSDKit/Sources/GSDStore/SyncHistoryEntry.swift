import Foundation

/// One recorded sync attempt (§7.7). Persisted in the `syncHistory` table; surfaced in the
/// Sync History screen. Written by `SyncEngine` at the end of each `sync()`/`pushNow()`.
public struct SyncHistoryEntry: Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case success, error, conflict, partial }
    public enum TriggeredBy: String, Codable, Sendable { case user, auto }

    public var id: String
    public var timestamp: Int            // ms when the attempt finished
    public var status: Status
    public var pushedCount: Int
    public var pulledCount: Int
    public var conflictsResolved: Int
    public var failedCount: Int?
    public var errorMessage: String?
    public var duration: Int?            // ms
    public var deviceId: String
    public var triggeredBy: TriggeredBy

    public init(id: String, timestamp: Int, status: Status, pushedCount: Int = 0,
                pulledCount: Int = 0, conflictsResolved: Int = 0, failedCount: Int? = nil,
                errorMessage: String? = nil, duration: Int? = nil, deviceId: String,
                triggeredBy: TriggeredBy) {
        self.id = id; self.timestamp = timestamp; self.status = status
        self.pushedCount = pushedCount; self.pulledCount = pulledCount
        self.conflictsResolved = conflictsResolved; self.failedCount = failedCount
        self.errorMessage = errorMessage; self.duration = duration
        self.deviceId = deviceId; self.triggeredBy = triggeredBy
    }
}

/// Aggregate counts for the Sync History screen header.
public struct SyncHistoryStats: Equatable, Sendable {
    public var totalSyncs: Int
    public var successes: Int
    public var totalPushed: Int
    public var totalPulled: Int
    public init(totalSyncs: Int = 0, successes: Int = 0, totalPushed: Int = 0, totalPulled: Int = 0) {
        self.totalSyncs = totalSyncs; self.successes = successes
        self.totalPushed = totalPushed; self.totalPulled = totalPulled
    }
}
