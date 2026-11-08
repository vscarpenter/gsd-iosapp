import Foundation
import Observation
import WatchConnectivity
import WidgetKit
import GSDModel
import GSDSnapshot

/// The watch's thin client (spec 5). It holds the last snapshot from the iPhone and a queue of
/// commands for it. It never writes tasks: every change is a `WatchCommand` that `WatchOverlay`
/// shows on top of the snapshot until the iPhone reports it applied.
@MainActor @Observable
final class WatchModel: NSObject {
    /// Offered for 4 seconds after Complete (spec 6.4).
    struct UndoOffer: Equatable {
        let task: WatchTask
        let commandID: String
    }

    private(set) var snapshot: WatchSnapshot
    private(set) var outbox: WatchOutbox
    private(set) var undoOffer: UndoOffer?

    private let snapshotStore: WatchSnapshotStore
    private var undoExpiry: _Concurrency.Task<Void, Never>?

    override init() {
        let directory = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        snapshotStore = WatchSnapshotStore(directoryURL: directory)
        outbox = WatchOutbox(directoryURL: directory)
        snapshot = snapshotStore.read() ?? .empty
        super.init()
    }

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// What to draw now: the snapshot with the unacknowledged commands on top.
    func lists(now: Date = .now) -> WatchLists {
        WatchOverlay.apply(snapshot, pending: outbox.commands, now: now,
                           calendar: .current, timeZone: .current)
    }

    var hasSnapshot: Bool { snapshot.generatedAt != WatchSnapshot.empty.generatedAt }

    // MARK: Commands

    func complete(_ task: WatchTask) {
        let command = queue(.complete(taskID: task.id))
        undoOffer = UndoOffer(task: task, commandID: command?.id ?? "")
        undoExpiry?.cancel()
        undoExpiry = _Concurrency.Task { [weak self] in
            try? await _Concurrency.Task.sleep(for: .seconds(4))
            if !_Concurrency.Task.isCancelled { self?.undoOffer = nil }
        }
    }

    func markUrgent(_ task: WatchTask) { queue(.markUrgent(taskID: task.id)) }

    func capture(text: String, quadrant: Quadrant) { queue(.capture(text: text, quadrant: quadrant)) }

    /// Removes the queued `complete` if it never left, otherwise queues a `reopen`.
    func undo() {
        guard let offer = undoOffer else { return }
        undoOffer = nil
        undoExpiry?.cancel()
        switch WatchOverlay.undoComplete(commandID: offer.commandID, of: offer.task, outbox: outbox.commands) {
        case .removeFromOutbox(let id): try? outbox.remove(id: id)
        case .queueReopen(let taskID): queue(.reopen(taskID: taskID))
        case .unavailable: break
        }
    }

    /// Whether the offer can still be undone: a repeating task whose `complete` left has no Undo.
    var canUndo: Bool {
        guard let offer = undoOffer else { return false }
        return WatchOverlay.undoComplete(commandID: offer.commandID, of: offer.task,
                                         outbox: outbox.commands) != .unavailable
    }

    @discardableResult
    private func queue(_ kind: WatchCommand.Kind) -> WatchCommand? {
        let command = WatchCommand(id: UUID().uuidString, issuedAt: .now, kind: kind)
        do { try outbox.add(command) } catch { return nil }   // no container: nothing to show or send
        if let data = try? JSONEncoder().encode(command) {
            WCSession.default.transferUserInfo(["command": data])
        }
        return command
    }

    // MARK: Snapshot from the iPhone

    fileprivate func receive(_ snapshot: WatchSnapshot) {
        guard snapshot.generatedAt >= self.snapshot.generatedAt else { return }   // a late, older context
        self.snapshot = snapshot
        try? snapshotStore.write(snapshot)
        try? outbox.drop(acknowledged: Set(snapshot.appliedCommandIDs))
        WidgetCenter.shared.reloadAllTimelines()
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // A context that arrived while the app wasn't running is waiting here.
        guard let snapshot = Self.decode(session.receivedApplicationContext) else { return }
        _Concurrency.Task { @MainActor in self.receive(snapshot) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = Self.decode(applicationContext) else { return }
        _Concurrency.Task { @MainActor in self.receive(snapshot) }
    }

    private nonisolated static func decode(_ context: [String: Any]) -> WatchSnapshot? {
        guard let data = context["snapshot"] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
