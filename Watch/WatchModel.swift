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
        let directory = Self.storageDirectory()
        snapshotStore = WatchSnapshotStore(directoryURL: directory)
        outbox = WatchOutbox(directoryURL: directory)
        snapshot = snapshotStore.read() ?? .empty
        super.init()
    }

    /// The App Group container, else Application Support, created first because the outbox
    /// writes into it and the system doesn't make that directory.
    private static func storageDirectory() -> URL? {
        let files = FileManager.default
        if let group = files.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.id) { return group }
        guard let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? files.createDirectory(at: support, withIntermediateDirectories: true)
        return support
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
        // No Undo for a command that never queued: there is nothing to take back.
        guard let command = queue(.complete(taskID: task.id)) else { return }
        undoOffer = UndoOffer(task: task, commandID: command.id)
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
        send(command)
        return command
    }

    private func send(_ command: WatchCommand) {
        if let payload = WatchWire.userInfo(for: command) { WCSession.default.transferUserInfo(payload) }
    }

    /// Hands the session every unacknowledged command it isn't already carrying. The phone
    /// leaves an id unrecorded when its store errors, so the watch has to offer it again; a
    /// repeat is safe because the phone skips ids it has applied.
    private func resendUnsent() {
        let inFlight = Set(WCSession.default.outstandingUserInfoTransfers
            .compactMap { WatchWire.command(from: $0.userInfo)?.id })
        outbox.unsent(excluding: inFlight).forEach(send)
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
        let snapshot = Self.decode(session.receivedApplicationContext)
        _Concurrency.Task { @MainActor in
            if let snapshot { self.receive(snapshot) }
            self.resendUnsent()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer,
                             error: Error?) {
        guard error != nil else { return }
        _Concurrency.Task { @MainActor in self.resendUnsent() }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let snapshot = Self.decode(applicationContext) else { return }
        _Concurrency.Task { @MainActor in self.receive(snapshot) }
    }

    private nonisolated static func decode(_ context: [String: Any]) -> WatchSnapshot? {
        guard let data = context[WatchWire.snapshotKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
