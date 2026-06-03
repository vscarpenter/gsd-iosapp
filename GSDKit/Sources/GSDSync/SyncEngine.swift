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

public enum SyncTrigger: Sendable { case launch, signIn, manual, foreground, periodic, networkRegained, mutation }

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
    private let history: any SyncHistoryRepository
    private var isSyncing = false
    private var isErasing = false      // §3.4: suppresses pull during a destructive erase/replace drain (Group D)

    public init(client: PocketBaseClient, tasks: any TaskRepository, queue: any SyncQueueRepository,
                cursor: SyncCursor, deviceId: String,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                now: @escaping @Sendable () -> Date = { Date() },
                throttleMs: Int = 100,
                history: any SyncHistoryRepository = NoopSyncHistoryRepository()) {
        self.client = client; self.tasks = tasks; self.queue = queue; self.cursor = cursor
        self.deviceId = deviceId; self.tokenProvider = tokenProvider; self.now = now
        self.throttleMs = throttleMs; self.history = history
    }

    /// Pull remote → local (upsert-only; no deletes). LWW vs local; device-local preserved via the
    /// mapper merge. Returns the applied count + the max `client_updated_at` seen (for cursor advance).
    func pull(token: String, since: String) async throws -> (applied: Int, conflicts: Int, maxApplied: Date?) {
        if isErasing { return (0, 0, nil) }       // §3.4 pull-suppression gate (set during a destructive drain)
        let records = try await client.listTasks(updatedSince: since, token: token)
        var applied = 0
        var conflicts = 0
        var maxApplied: Date?
        for record in records {
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { continue }
            maxApplied = max(maxApplied ?? .distantPast, remoteUpdated)
            let local = try await tasks.fetch(id: record.taskId)
            // Upsert when there's no local copy, or the remote is strictly newer (LWW).
            let decision = LWW.resolve(localUpdatedAt: local?.updatedAt, remoteClientUpdatedAt: remoteUpdated)
            guard local == nil || decision == .takeRemote else { continue }
            if local != nil && decision == .takeRemote { conflicts += 1 }   // a real conflict resolved in remote's favor
            try await tasks.upsert(TaskWireMapper.toDomain(record, mergingInto: local))
            applied += 1
        }
        return (applied, conflicts, maxApplied)
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
        let start = now()
        do {
            if cursor.load() == nil { try await seedExistingTasks() }      // first-sync seed BEFORE pull/reconcile
            let since = cursor.load() ?? "1970-01-01T00:00:00.000Z"
            let (pulled, conflicts, maxApplied) = try await pull(token: token, since: since)
            result.pulled = pulled
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            result.deleted = try await reconcileDeletions(token: token)    // destructive — last
            cursor.advance(maxApplied: maxApplied, now: now())
            await record(trigger: trigger, result: result, conflicts: conflicts, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: trigger, result: result, conflicts: 0, start: start)
        }
        return result
    }

    // MARK: History (§7.7)

    /// Map a trigger to history's user/auto axis. Only explicit Sync-Now / pull-to-refresh is "user".
    private func triggeredBy(_ trigger: SyncTrigger) -> SyncHistoryEntry.TriggeredBy {
        trigger == .manual ? .user : .auto
    }

    /// Build + persist one history entry for a completed attempt. Status precedence: error > partial
    /// (some pushes failed) > conflict (LWW resolved a remote-wins overwrite) > success.
    private func record(trigger: SyncTrigger, result: SyncResult, conflicts: Int, start: Date) async {
        let end = now()
        let status: SyncHistoryEntry.Status =
            result.error != nil ? .error :
            result.failed > 0   ? .partial :
            conflicts > 0       ? .conflict : .success
        let entry = SyncHistoryEntry(
            id: UUID().uuidString,
            timestamp: Int(end.timeIntervalSince1970 * 1000),
            status: status, pushedCount: result.pushed, pulledCount: result.pulled,
            conflictsResolved: conflicts, failedCount: result.failed > 0 ? result.failed : nil,
            errorMessage: result.error, duration: Int(end.timeIntervalSince(start) * 1000),
            deviceId: deviceId, triggeredBy: triggeredBy(trigger))
        try? await history.insert(entry)
        try? await history.prune(keeping: 500)
    }

    /// Read passthroughs for the Sync History screen (keeps GSDSync the single sync API surface).
    public func recentHistory(limit: Int = 50) async -> [SyncHistoryEntry] {
        (try? await history.recent(limit: limit)) ?? []
    }
    public func historyStats() async -> SyncHistoryStats {
        (try? await history.stats()) ?? SyncHistoryStats()
    }
}
