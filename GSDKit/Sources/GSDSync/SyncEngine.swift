import Foundation
import GSDModel
import GSDStore

/// The result of a sync attempt (§7.7 recording is 5d; 5c returns this for triggers/logging).
public struct SyncResult: Equatable, Sendable {
    public var pulled = 0
    public var pushed = 0
    public var deleted = 0
    public var failed = 0
    public var skipped = false       // a concurrent sync was in-flight (dropped)
    public var notSignedIn = false
    public var error: String?
}

public enum SyncTrigger: Sendable { case launch, signIn, manual }

/// Bidirectional active-task sync (§7.4–7.5). Writes pulled tasks DIRECTLY via the repository
/// (preserving the wire `client_updated_at`; never re-stamping; never enqueuing). `actor` for state
/// safety; single-flight is an explicit `isSyncing` drop. The `sync()` orchestration is added in Group C.
public actor SyncEngine {
    private let client: PocketBaseClient
    private let tasks: any TaskRepository
    private let queue: any SyncQueueRepository
    private let cursor: SyncCursor
    private let deviceId: String
    private let tokenProvider: @Sendable () async throws -> String?
    private let now: @Sendable () -> Date
    private let throttleMs: Int
    private var isSyncing = false

    public init(client: PocketBaseClient, tasks: any TaskRepository, queue: any SyncQueueRepository,
                cursor: SyncCursor, deviceId: String,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                now: @escaping @Sendable () -> Date = { Date() },
                throttleMs: Int = 100) {
        self.client = client; self.tasks = tasks; self.queue = queue; self.cursor = cursor
        self.deviceId = deviceId; self.tokenProvider = tokenProvider; self.now = now
        self.throttleMs = throttleMs
    }

    /// Pull remote → local (upsert-only; no deletes). LWW vs local; device-local preserved via the
    /// mapper merge. Returns the applied count + the max `client_updated_at` seen (for cursor advance).
    func pull(token: String, since: String) async throws -> (applied: Int, maxApplied: Date?) {
        let records = try await client.listTasks(updatedSince: since, token: token)
        var applied = 0
        var maxApplied: Date?
        for record in records {
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { continue }
            maxApplied = max(maxApplied ?? .distantPast, remoteUpdated)
            let local = try await tasks.fetch(id: record.taskId)
            // Upsert when there's no local copy, or the remote is strictly newer (LWW).
            let decision = LWW.resolve(localUpdatedAt: local?.updatedAt, remoteClientUpdatedAt: remoteUpdated)
            guard local == nil || decision == .takeRemote else { continue }
            try await tasks.upsert(TaskWireMapper.toDomain(record, mergingInto: local))
            applied += 1
        }
        return (applied, maxApplied)
    }

    /// First-sign-in data-wipe guard (§7.4/§7.5): enqueue every existing local active task as a push
    /// BEFORE any pull/reconcile, so pre-sign-in tasks are both uploaded and protected (they're then
    /// "in the queue" → deletion-reconcile skips them). Called by `sync()` only when the cursor is unset.
    func seedExistingTasks() async throws {
        for task in try await tasks.fetchAll() {
            try await queue.enqueue(SyncQueueItem(
                id: UUID().uuidString, taskId: task.id, operation: .update,
                timestamp: Int(now().timeIntervalSince1970 * 1000), payload: task))
        }
    }
}
