import Foundation
import WatchConnectivity
import GSDModel
import GSDStore
import GSDSnapshot

/// The iPhone end of the watch link (spec 6.2 and 6.3). It sends the latest `WatchSnapshot` with
/// `updateApplicationContext` and applies the commands the watch queues with `transferUserInfo`,
/// through the same `TaskStore` paths the iPhone UI uses. The decisions are the tested
/// `WatchCommandPlan`; this type is the glue. It does nothing where `WCSession` is unsupported
/// (Mac Catalyst, iPad without a pairing) or when `enabled` is false (the isolated harness).
@MainActor
final class WatchSessionCoordinator: NSObject {
    /// The key both ends use in the application context dictionary.
    nonisolated static let snapshotKey = "snapshot"

    private let store: TaskStore
    private let defaults: UserDefaults
    private let enabled: Bool
    private let now: () -> Date
    private let debounce: Duration
    private var ledger: WatchAppliedLedger
    private var debounceTask: _Concurrency.Task<Void, Never>?
    private var commandLoop: _Concurrency.Task<Void, Never>?
    private var lastSent: Data?

    /// Commands arrive on a WatchConnectivity queue. One stream, one consumer, so they apply in
    /// the order the watch sent them even though each apply awaits the database.
    private nonisolated let commands: AsyncStream<WatchCommand>
    private nonisolated let commandSink: AsyncStream<WatchCommand>.Continuation

    init(store: TaskStore, enabled: Bool,
         defaults: UserDefaults = AppGroupDefaults.shared,
         now: @escaping () -> Date = { Date() },
         debounce: Duration = .seconds(1)) {
        self.store = store
        self.enabled = enabled
        self.defaults = defaults
        self.now = now
        self.debounce = debounce
        self.ledger = WatchAppliedLedger(defaults: defaults)
        (self.commands, self.commandSink) = AsyncStream.makeStream(of: WatchCommand.self)
        super.init()
    }

    private var session: WCSession? {
        enabled && WCSession.isSupported() ? WCSession.default : nil
    }

    func start() {
        guard let session, commandLoop == nil else { return }
        session.delegate = self
        session.activate()
        commandLoop = _Concurrency.Task { [weak self, commands] in
            for await command in commands { await self?.apply(command) }
        }
    }

    /// Coalesce a burst of task changes into one send.
    func schedule() {
        guard session != nil else { return }
        debounceTask?.cancel()
        debounceTask = _Concurrency.Task { [weak self] in
            guard let self else { return }
            try? await _Concurrency.Task.sleep(for: self.debounce)
            if _Concurrency.Task.isCancelled { return }
            self.sendSnapshot()
        }
    }

    // MARK: Phone to watch

    private func sendSnapshot() {
        guard let session, session.activationState == .activated,
              session.isPaired, session.isWatchAppInstalled,
              store.hasLoadedTasks else { return }   // an empty first emission must not blank the watch
        let window = EscalationWindow.load(from: defaults)
        let snapshot = WatchSnapshotBuilder.build(
            from: store.tasks, now: now(),
            escalationWindowDays: window.days,
            appliedCommandIDs: ledger.ids)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        // `generatedAt` changes every build, so compare the payload with it held fixed.
        var stable = snapshot; stable.generatedAt = .distantPast
        let fingerprint = try? JSONEncoder().encode(stable)
        guard fingerprint != lastSent else { return }
        do {
            try session.updateApplicationContext([Self.snapshotKey: data])
            lastSent = fingerprint
        } catch {
            // Not paired or not reachable right now; the next task change sends again.
        }
    }

    // MARK: Watch to phone

    private func apply(_ command: WatchCommand) async {
        let task: Task?
        do { task = try await store.fetchTask(id: command.taskID ?? "") }
        catch { return }   // database unavailable: leave the id unrecorded so a retry can apply it
        let decision = WatchCommandPlan.decide(command, task: task, alreadyApplied: ledger.contains(command.id))
        if case .apply(let action) = decision {
            do { try await perform(action, on: task) }
            catch { return }   // a failed write stays unrecorded; the watch keeps the command pending
        }
        ledger.record(command.id)
        schedule()
    }

    private func perform(_ action: WatchCommandPlan.Action, on task: Task?) async throws {
        switch action {
        case .toggleComplete:
            if let task { try await store.toggleComplete(task) }
        case .move(let quadrant):
            if let task { try await store.move(task, to: quadrant) }
        case .snoozeOneHour:
            if let task { try await store.snooze(task, by: .oneHour) }
        case .capture(let text, let quadrant):
            try await store.add(CaptureParser.parse(text), override: quadrant)
        }
    }
}

extension WatchSessionCoordinator: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        _Concurrency.Task { @MainActor in self.schedule() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    /// A different watch was paired; activate again to follow it.
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        _Concurrency.Task { @MainActor in self.schedule() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo["command"] as? Data,
              let command = try? JSONDecoder().decode(WatchCommand.self, from: data) else { return }
        commandSink.yield(command)
    }
}
