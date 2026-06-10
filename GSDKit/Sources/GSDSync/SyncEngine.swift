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
    private let rawToken: @Sendable () -> String?
    private let now: @Sendable () -> Date
    private let throttleMs: Int
    private let history: any SyncHistoryRepository
    private var isSyncing = false
    private var isErasing = false      // §3.4: suppresses pull during a destructive erase/replace drain (Group D)

    /// `rawToken` reads the STORED token without validation/refresh — only `health()` uses it, so
    /// an expired-but-present session can still be reported as "session expired" (the validating
    /// `tokenProvider` throws in that state and carries no expiry).
    public init(client: PocketBaseClient, tasks: any TaskRepository, queue: any SyncQueueRepository,
                cursor: SyncCursor, deviceId: String,
                tokenProvider: @escaping @Sendable () async throws -> String?,
                rawToken: @escaping @Sendable () -> String? = { nil },
                now: @escaping @Sendable () -> Date = { Date() },
                throttleMs: Int = 100,
                history: any SyncHistoryRepository = NoopSyncHistoryRepository()) {
        self.client = client; self.tasks = tasks; self.queue = queue; self.cursor = cursor
        self.deviceId = deviceId; self.tokenProvider = tokenProvider; self.rawToken = rawToken
        self.now = now; self.throttleMs = throttleMs; self.history = history
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
        var index = try await client.remoteIndex(token: token)
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
                    else {
                        // Record the new recordId in the live index so a later same-drain DELETE for the
                        // same task_id finds it (else the create leaks an orphan remote record).
                        let newRecordId = try await client.createTask(wire, token: token)
                        index[item.taskId] = (recordId: newRecordId, clientUpdatedAt: payload.updatedAt)
                    }
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
    /// (archived is a separate repo, out of scope). `allTaskIds()` = pending + failed (both
    /// protect) and is read AFTER `fetchAll` — TaskStore enqueues before it upserts, so any task
    /// in the snapshot already has its protection visible to this later read (Fix E).
    func reconcileDeletions(token: String) async throws -> Int {
        let remoteIds = Set(try await client.remoteIndex(token: token).keys)
        let snapshot = try await tasks.fetchAll()
        let queuedIds = try await queue.allTaskIds()
        var deleted = 0
        for task in snapshot where !remoteIds.contains(task.id) && !queuedIds.contains(task.id) {
            try await tasks.delete(id: task.id); deleted += 1
        }
        return deleted
    }

    /// Reset every `.failed` queue item to `.pending` (fresh retry budget) so the next push drains
    /// it. Without this, `.failed` is a terminal state and the affected edits never leave the device.
    func requeueFailed() async throws {
        for item in try await queue.all() where item.status == .failed {
            var revived = item
            revived.status = .pending; revived.retryCount = 0
            revived.lastAttemptAt = nil; revived.failedAt = nil
            try await queue.update(revived)
        }
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
        } catch {
            // A throwing provider is NOT "signed out" — a session exists but couldn't be validated
            // (expired + refresh unavailable). Surface it; a silent no-op hides a dead session.
            result.error = String("\(error)".prefix(200))
            return result
        }

        guard let owner = JWT.userId(token) else {
            result.error = "Could not derive owner from auth token"   // malformed token → fail fast (don't push owner:"")
            return result
        }
        let start = now()
        do {
            if cursor.load() == nil { try await seedExistingTasks() }      // first-sync seed BEFORE pull/reconcile
            // §7.7 promises "tap Sync Now to retry" — an explicit user retry (or the network
            // coming back) revives `.failed` items so the push loop drains them again.
            if trigger == .manual || trigger == .networkRegained { try await requeueFailed() }
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

    /// Push-only fast path for the debounced post-mutation trigger (§7.6): drains the queue with the
    /// same LWW-guard / throttle / 429-abort / across-sync-retry as `sync()`, but does NOT pull or
    /// reconcile. Shares the single-flight flag (a concurrent full `sync()` drops it). Records history.
    public func pushNow(trigger: SyncTrigger = .mutation) async -> SyncResult {
        await drain(suppressPull: false, trigger: trigger)
    }

    /// Shared single-flight queue-drain (token → owner → push → record). `suppressPull` holds the
    /// §3.4 gate for the duration so a concurrent `sync()`'s pull can't interleave (import-replace).
    private func drain(suppressPull: Bool, trigger: SyncTrigger) async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true; isErasing = suppressPull
        defer { isSyncing = false; isErasing = false }
        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch {
            result.error = String("\(error)".prefix(200))   // dead session ≠ signed out (see sync())
            return result
        }
        guard let owner = JWT.userId(token) else {
            result.error = "Could not derive owner from auth token"; return result
        }
        let start = now()
        do {
            let (pushed, failed) = try await push(token: token, owner: owner)
            result.pushed = pushed; result.failed = failed
            await record(trigger: trigger, result: result, conflicts: 0, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: trigger, result: result, conflicts: 0, start: start)
        }
        return result
    }

    // MARK: Destructive ops (§3.4)

    /// Erase-all remote wipe: with pull suppressed, AUTHORITATIVELY delete every remote record from a
    /// fresh index, then clear the local queue so no stale pending op can resurrect a task after the
    /// App wipes local. Direct deletes (not via the queue) avoid a create-then-delete orphan race and
    /// give an honest success/failure the caller checks BEFORE clearing local. Signed-out → no-op.
    public func eraseAllRemote() async -> SyncResult {
        guard !isSyncing else { return SyncResult(skipped: true) }
        isSyncing = true; isErasing = true
        defer { isSyncing = false; isErasing = false }
        var result = SyncResult()
        let token: String
        do {
            guard let t = try await tokenProvider() else { result.notSignedIn = true; return result }
            token = t
        } catch {
            // CRITICAL distinction: nil = genuinely signed out (caller may erase local-only);
            // a throw = a session EXISTS but can't be validated — report an error so the caller
            // refuses the local wipe (otherwise "erase everywhere" would wipe local, report
            // success, and leave every task alive on the server).
            result.error = String("\(error)".prefix(200))
            return result
        }
        guard JWT.userId(token) != nil else {
            result.error = "Could not derive owner from auth token"; return result
        }
        let start = now()
        do {
            let index = try await client.remoteIndex(token: token)
            for (_, ref) in index {
                try await client.deleteTask(recordId: ref.recordId, token: token)
                result.pushed += 1
                if throttleMs > 0 { try? await _Concurrency.Task.sleep(for: .milliseconds(throttleMs)) }
            }
            // Full wipe → no pending op should survive (they'd recreate/clobber). Clear the queue only
            // after every remote delete succeeded; a partial failure throws first → queue intact → retry.
            for item in try await queue.all() { try await queue.remove(id: item.id) }
            await record(trigger: .manual, result: result, conflicts: 0, start: start)
        } catch {
            result.error = String("\(error)".prefix(200))
            await record(trigger: .manual, result: result, conflicts: 0, start: start)
        }
        return result
    }

    /// Drain pending deletes (from a destructive import-replace) with pull suppressed. The deletes
    /// were already enqueued by `TaskStore.importTasks(replace)`; this just pushes them safely.
    public func flushDeletes() async -> SyncResult {
        await drain(suppressPull: true, trigger: .manual)
    }

    /// Test seam (§3.4): set the pull-suppression gate directly so the suppression is unit-testable.
    func setErasing(_ value: Bool) { isErasing = value }

    // MARK: Realtime (§7.6)

    /// Apply one realtime (SSE) message. Same rules as pull: write via the repo directly (no enqueue,
    /// no re-stamp), LWW vs local, device-local preserved by the mapper merge. Enforces the owner check;
    /// echo-filters our own `device_id` on create/update (a DELETE event carries the last *writer's*
    /// device_id, not the deleter's, so it must NOT be echo-filtered). A create/update is skipped when a
    /// local `.delete` is pending (don't resurrect a just-deleted task); a delete is skipped when ANY op
    /// is pending for that task (queue-aware, like reconcile). Malformed/task_id-less payloads are
    /// skipped (the cadence safety-net reconciles).
    public func applyRealtime(rawData: String) async {
        guard let data = rawData.data(using: .utf8),
              let event = try? JSONDecoder().decode(RealtimeEvent.self, from: data),
              let record = event.record else { return }
        if !record.owner.isEmpty {
            guard let token = try? await tokenProvider(),
                  let owner = JWT.userId(token),
                  record.owner == owner
            else { return }       // fail closed when the event has an owner we cannot validate
        }
        let pending = (try? await queue.all()) ?? []
        switch event.action {
        case .create, .update:
            if !record.deviceId.isEmpty && record.deviceId == deviceId { return }   // echo-filter own writes
            // Don't resurrect a task the user just deleted locally (its .delete is queued, not yet pushed).
            if pending.contains(where: { $0.taskId == record.taskId && $0.operation == .delete }) { return }
            guard let remoteUpdated = WireDate.parse(record.clientUpdatedAt) else { return }
            let local = try? await tasks.fetch(id: record.taskId)
            let decision = LWW.resolve(localUpdatedAt: local?.updatedAt, remoteClientUpdatedAt: remoteUpdated)
            guard local == nil || decision == .takeRemote else { return }
            try? await tasks.upsert(TaskWireMapper.toDomain(record, mergingInto: local))
        case .delete:
            if pending.contains(where: { $0.taskId == record.taskId }) { return }   // queue-aware
            try? await tasks.delete(id: record.taskId)
        }
    }

    // MARK: History (§7.7)

    /// Map a trigger to history's user/auto axis. Only explicit Sync-Now / pull-to-refresh is "user".
    private func triggeredBy(_ trigger: SyncTrigger) -> SyncHistoryEntry.TriggeredBy {
        trigger == .manual ? .user : .auto
    }

    /// Build + persist one history entry for a completed attempt. Status precedence: error > partial
    /// (some pushes failed) > success. `conflictsResolved` is recorded as an informational count of
    /// remote updates LWW applied over an existing local copy — a routine multi-device pull, NOT an
    /// error condition, so it does not downgrade an otherwise-clean sync away from `.success`.
    private func record(trigger: SyncTrigger, result: SyncResult, conflicts: Int, start: Date) async {
        let end = now()
        let status: SyncHistoryEntry.Status =
            result.error != nil ? .error :
            result.failed > 0   ? .partial : .success
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

    // MARK: Status (§7.7)

    /// Pending push count for the status chip.
    public func pendingCount() async -> Int { (try? await queue.pending().count) ?? 0 }

    /// Compute current health (§7.7) from the queue + token + reachability (the App supplies `online`).
    /// Falls back to `rawToken` when validation throws — an expired-but-present session must still
    /// surface its expiry (that's exactly the state "session expired — sign in again" describes).
    public func health(online: Bool) async -> SyncHealth {
        let items = (try? await queue.all()) ?? []
        let oldestPendingMs = items.filter { $0.status == .pending }.map(\.timestamp).min()
        let failedCount = items.filter { $0.status == .failed }.count
        let token = ((try? await tokenProvider()).flatMap { $0 }) ?? rawToken()
        let expiry = token.flatMap { JWT.expiry($0) }
        return SyncHealth.evaluate(oldestPendingMs: oldestPendingMs, failedCount: failedCount,
                                   tokenExpiry: expiry, online: online, now: now())
    }
}
