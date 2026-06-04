import Foundation
import Observation
import Network
import GSDSync
import GSDStore

/// Owns *when* sync fires and *what status shows* (§7.6/§7.7). The pure `SyncEngine` stays the
/// tested core; this is the app-lifecycle wrapper (the `SessionStore`-wraps-`AuthService` precedent).
/// Owns the 2-min cadence, reachability, scenePhase reactions, the debounced post-mutation push, and
/// (Group C) the SSE subscription lifecycle. `@MainActor @Observable` so the chip + Settings observe it.
@MainActor
@Observable
final class SyncCoordinator {
    enum Phase: Equatable { case idle, syncing, error }

    private(set) var phase: Phase = .idle
    private(set) var pendingCount = 0
    private(set) var lastSync: SyncResult?
    private(set) var health = SyncHealth(level: .ok, message: nil)

    private let engine: SyncEngine
    private let realtime: PocketBaseRealtime
    private let tokenProvider: @Sendable () async -> String?
    private let signedIn: @MainActor () -> Bool

    /// The engine, for the read-only Sync History screen.
    var engineForHistory: SyncEngine { engine }

    @ObservationIgnored private var cadenceTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var debounceTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var sseTask: _Concurrency.Task<Void, Never>?
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var online = true
    @ObservationIgnored private var active = false

    init(engine: SyncEngine, realtime: PocketBaseRealtime,
         tokenProvider: @escaping @Sendable () async -> String?,
         signedIn: @escaping @MainActor () -> Bool) {
        self.engine = engine
        self.realtime = realtime
        self.tokenProvider = tokenProvider
        self.signedIn = signedIn
    }

    // MARK: Lifecycle

    /// Launch / after-sign-in: begin cadence + reachability + SSE and run an initial sync.
    func start(trigger: SyncTrigger = .launch) {
        guard signedIn() else { return }
        resume(trigger: trigger)
    }

    /// Shared bring-up for launch and foreground-return (kept in one place so the two entry points
    /// never diverge in which subsystems they spin up). Cadence/SSE cancel-and-restart; reachability
    /// is idempotent (`guard monitor == nil`).
    private func resume(trigger: SyncTrigger) {
        active = true
        startReachability()
        startCadence()
        startSSE()
        _Concurrency.Task { await self.runSync(trigger: trigger) }
    }

    /// Sign-out / teardown: stop everything (local data is NOT wiped).
    func stop() {
        active = false
        cadenceTask?.cancel(); cadenceTask = nil
        debounceTask?.cancel(); debounceTask = nil
        sseTask?.cancel(); sseTask = nil
        monitor?.cancel(); monitor = nil
        phase = .idle; pendingCount = 0
    }

    /// Sign-out: tear down AND reset the engine's pull cursor (re-seed + full-pull next sign-in;
    /// local tasks are NOT wiped). Keeps the engine out of `SessionStore`.
    func signedOut() {
        stop()
        _Concurrency.Task { await engine.resetCursor() }
    }

    func enteredForeground() {
        guard signedIn() else { return }
        resume(trigger: .foreground)
    }

    func enteredBackground() {
        active = false
        cadenceTask?.cancel(); cadenceTask = nil
        sseTask?.cancel(); sseTask = nil
        monitor?.cancel(); monitor = nil
    }

    // MARK: Triggers

    /// Manual "Sync Now" + pull-to-refresh.
    func syncNow() async { await runSync(trigger: .manual) }

    /// §3.4 erase everywhere: wipe remote (pull suppressed) THEN clear local. Returns whether the erase
    /// completed. Wipes local ONLY when the remote side is handled — signed-out (local-only erase is the
    /// intent) or a clean signed-in wipe — so a remote wipe dropped by single-flight (a cadence/SSE/
    /// debounced sync was in-flight) or failed by network does NOT leave local empty while remote is
    /// intact (which would just re-pull every task back). Retries a single-flight skip a few times.
    @discardableResult
    func eraseEverywhere(store: TaskStore) async -> Bool {
        var result = await engine.eraseAllRemote()
        var tries = 0
        while result.skipped && tries < 5 {
            try? await _Concurrency.Task.sleep(for: .milliseconds(400))
            result = await engine.eraseAllRemote()
            tries += 1
        }
        guard result.notSignedIn || (result.error == nil && !result.skipped) else {
            await refreshStatus()
            return false
        }
        do {
            try await store.eraseAllData()
        } catch {
            await refreshStatus()
            return false
        }
        await refreshStatus()
        return true
    }

    /// §3.4 after a destructive import-replace: drain the cleared-task deletes under the gate.
    func flushAfterReplace() async {
        _ = await engine.flushDeletes()
        await refreshStatus()
    }

    /// Debounced post-mutation push — called from `TaskStore.onMutation`. Coalesces rapid edits.
    func scheduleDebouncedPush() {
        guard signedIn() else { return }
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .milliseconds(1500))
            guard let self, !_Concurrency.Task.isCancelled else { return }
            await self.runPush()
        }
    }

    // MARK: Internals

    private func startCadence() {
        cadenceTask?.cancel()
        cadenceTask = _Concurrency.Task { [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(for: .seconds(120))
                guard let self, !_Concurrency.Task.isCancelled, self.active else { return }
                await self.runSync(trigger: .periodic)
            }
        }
    }

    /// Foreground-only realtime: stream `tasks` events → `applyRealtime`; on stream end/error run a
    /// full sync (catch missed events) and reconnect with capped backoff while active + signed-in.
    private func startSSE() {
        sseTask?.cancel()
        sseTask = _Concurrency.Task { [weak self] in
            var backoff = 1.0
            while let self, !_Concurrency.Task.isCancelled, self.signedIn(), self.active {
                guard let token = await self.tokenProvider() else {
                    // Transient token gap (refresh in flight) — back off and retry; don't kill realtime
                    // for the whole foreground session. A real sign-out drops `signedIn()` → loop exits.
                    try? await _Concurrency.Task.sleep(for: .seconds(min(backoff, 30)))
                    backoff = min(backoff * 2, 30)
                    continue
                }
                do {
                    for try await data in self.realtime.events(token: token) {
                        if _Concurrency.Task.isCancelled { return }
                        backoff = 1.0                       // a healthy stream resets the reconnect backoff
                        await self.engine.applyRealtime(rawData: data)
                        await self.refreshStatus()
                    }
                } catch { /* fall through to reconnect */ }
                if _Concurrency.Task.isCancelled { return }
                await self.runSync(trigger: .foreground)   // reconnect → catch missed events
                try? await _Concurrency.Task.sleep(for: .seconds(min(backoff, 30)))
                backoff = min(backoff * 2, 30)
            }
        }
    }

    private func startReachability() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let nowOnline = path.status == .satisfied
            _Concurrency.Task { @MainActor in
                guard let self else { return }
                let regained = nowOnline && !self.online
                self.online = nowOnline
                await self.refreshHealth()
                if regained, self.signedIn(), self.active {
                    await self.runSync(trigger: .networkRegained)
                }
            }
        }
        m.start(queue: DispatchQueue(label: "dev.vinny.gsd.reachability"))
        monitor = m
    }

    private func runSync(trigger: SyncTrigger) async {
        phase = .syncing
        let result = await engine.sync(trigger: trigger)
        apply(result)
    }

    private func runPush() async {
        phase = .syncing
        let result = await engine.pushNow()
        apply(result)
    }

    private func apply(_ result: SyncResult) {
        if result.skipped { return }                  // a concurrent in-flight sync owns the phase
        if !result.notSignedIn { lastSync = result }  // a no-op (no token) isn't a successful sync
        phase = result.error != nil ? .error : .idle
        _Concurrency.Task { await self.refreshStatus() }
    }

    private func refreshStatus() async {
        pendingCount = await engine.pendingCount()
        await refreshHealth()
    }

    private func refreshHealth() async {
        health = await engine.health(online: online)
    }
}
