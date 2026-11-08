import Foundation

/// The commands the watch has queued for the iPhone and not yet seen acknowledged (spec 6.3),
/// kept in a file so a relaunch still shows "waiting for iPhone". Order is the order added.
public struct WatchOutbox {
    public static let fileName = "watch-outbox.json"

    private let fileURL: URL?
    public private(set) var commands: [WatchCommand]

    public init(directoryURL: URL?) {
        self.fileURL = directoryURL?.appendingPathComponent(Self.fileName)
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([WatchCommand].self, from: data) {
            commands = saved
        } else {
            commands = []   // first launch, or a file that no longer decodes
        }
    }

    public mutating func add(_ command: WatchCommand) throws {
        commands.append(command)
        try save()
    }

    public mutating func remove(id: String) throws {
        commands.removeAll { $0.id == id }
        try save()
    }

    /// Drops commands whose id the iPhone reported as applied.
    public mutating func drop(acknowledged ids: Set<String>) throws {
        let before = commands.count
        commands.removeAll { ids.contains($0.id) }
        if commands.count != before { try save() }
    }

    /// The commands to hand to the session again: those not already queued in a transfer. The
    /// phone skips an id it has applied, so a repeat is safe (spec 6.3).
    public func unsent(excluding inFlight: Set<String>) -> [WatchCommand] {
        commands.filter { !inFlight.contains($0.id) }
    }

    private func save() throws {
        guard let fileURL else { throw WatchStoreError.noContainer }
        try JSONEncoder().encode(commands).write(to: fileURL, options: .atomic)
    }
}

/// Bounds the watch's resends (WATCH-REVIEW-FIX). Each command is offered again at most once per
/// session activation, so a persistent failure can't start a new transfer for every unsent
/// command on each error. The next activation clears the ledger and offers them again.
public struct WatchResendLedger {
    private var resent: Set<String> = []

    public init() {}

    public mutating func startActivation() { resent.removeAll() }

    /// The unsent commands not already resent this activation; marks them resent.
    public mutating func take(from outbox: WatchOutbox, excluding inFlight: Set<String>) -> [WatchCommand] {
        let due = outbox.unsent(excluding: inFlight.union(resent))
        resent.formUnion(due.map(\.id))
        return due
    }
}

public enum WatchStoreError: Error { case noContainer }
