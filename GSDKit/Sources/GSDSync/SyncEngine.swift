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

    private static let backoffSeconds: [TimeInterval] = [5, 10, 30, 60, 300]
    private func isDue(_ item: SyncQueueItem, nowMs: Int) -> Bool {
        guard let last = item.lastAttemptAt else { return true }        // never attempted → due
        let wait = Self.backoffSeconds[min(max(item.retryCount - 1, 0), Self.backoffSeconds.count - 1)]
        return nowMs >= last + Int(wait * 1000)
    }

    /// Drain the pending queue → remote (§7.5). Payload-LWW-guard (skip+drop a stale upsert iff remote
    /// `client_updated_at` > the payload's `updatedAt`); create(no recordId)/update(by recordId)/delete;
    /// ~throttle; 429 aborts the loop; across-sync retry (5/10/30/60/300 s) → `failed` after 5 (kept).
    func push(token: String, owner: String) async throws -> (pushed: Int, failed: Int) {
        let index = try await client.remoteIndex(token: token)
        let nowMs = Int(now().timeIntervalSince1970 * 1000)
        var pushed = 0, failed = 0
        for item in try await queue.pending() where isDue(item, nowMs: nowMs) {
            let remote = index[item.taskId]
            // payload-LWW-guard (upserts only): remote strictly newer than what we'd write → drop, let pull win.
            if item.operation != .delete, let payload = item.payload, let remoteUpdated = remote?.clientUpdatedAt,
               Int(remoteUpdated.timeIntervalSince1970 * 1000) > Int(payload.updatedAt.timeIntervalSince1970 * 1000) {
                try await queue.remove(id: item.id); continue
            }
            do {
                switch item.operation {
                case .delete:
                    if let recordId = remote?.recordId { try await client.deleteTask(recordId: recordId, token: token) }
                case .create, .update:
                    guard let payload = item.payload else { break }
                    let wire = TaskWireMapper.toWire(payload, owner: owner, deviceId: deviceId, recordId: remote?.recordId ?? "")
                    if let recordId = remote?.recordId { try await client.updateTask(recordId: recordId, record: wire, token: token) }
                    else { _ = try await client.createTask(wire, token: token) }
                }
                try await queue.remove(id: item.id); pushed += 1
                if throttleMs > 0 { try? await _Concurrency.Task.sleep(for: .milliseconds(throttleMs)) }
            } catch let e as PocketBaseError {
                if case .http(429, _) = e { break }                    // 429 → abort
                if case .pocketBase(429, _) = e { break }
                var f = item; f.retryCount += 1; f.lastAttemptAt = nowMs; f.lastError = String("\(e)".prefix(200))
                if f.retryCount >= 5 { f.status = .failed; f.failedAt = nowMs }
                try await queue.update(f); failed += 1
            }
        }
        return (pushed, failed)
    }

    /// §7.4 step 5 (destructive — runs LAST, over a FRESH post-push remote index): delete local
    /// ACTIVE tasks absent remotely AND not in the queue. `fetchAll()` is the active table only
    /// (archived is a separate repo, out of scope). `allTaskIds()` = pending + failed (both protect).
    func reconcileDeletions(token: String) async throws -> Int {
        let remoteIds = Set(try await client.remoteIndex(token: token).keys)
        let queuedIds = try await queue.allTaskIds()
        var deleted = 0
        for task in try await tasks.fetchAll() where !remoteIds.contains(task.id) && !queuedIds.contains(task.id) {
            try await tasks.delete(id: task.id); deleted += 1
        }
        return deleted
    }

    /// Clear the pull cursor (sign-out) so the next sign-in re-seeds + full-pulls. Local tasks are
    /// NOT wiped (offline-first).
    public func resetCursor() { cursor.clear() }

    /// Single-flight bidirectional sync (§7.4–7.7). A concurrent trigger is DROPPED (`skipped`),
    /// not queued. Sequence: token → seed-if-first → pull → push → deletion-reconcile → advance cursor.
    public func sync(trigger: SyncTrigger) async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true
        defer { isSyncing = false }

        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch { result.notSignedIn = true; return result }

        guard let owner = JWT.userId(token) else {
            result.error = "Could not derive owner from auth token"   // malformed token → fail fast (don't push owner:"")
            return result
        }
        do {
            if cursor.load() == nil { try await seedExistingTasks() }      // first-sync seed BEFORE pull/reconcile
            let since = cursor.load() ?? "1970-01-01T00:00:00.000Z"
            let (pulled, maxApplied) = try await pull(token: token, since: since)
            result.pulled = pulled
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            result.deleted = try await reconcileDeletions(token: token)    // destructive — last
            cursor.advance(maxApplied: maxApplied, now: now())
        } catch {
            result.error = String("\(error)".prefix(200))
        }
        return result
    }
}
