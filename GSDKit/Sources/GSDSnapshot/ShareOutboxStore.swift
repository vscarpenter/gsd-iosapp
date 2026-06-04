import Foundation
import GSDModel

/// The App-Group "outbox" the Share Extension writes and the app drains (spec §3, §6).
/// One file per capture so the extension's write and the app's drain never race on the same
/// file, and multiple shares before the app opens each survive.
public struct ShareOutboxStore: Sendable {
    public static let directoryName = "share-outbox"
    private let directoryURL: URL?

    /// Production: resolves `<AppGroup>/share-outbox/` (pure Foundation; GRDB-free).
    public init(appGroupID: String = AppGroup.id, fileManager: FileManager = .default) {
        self.directoryURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Test seam: inject a temp *container* directory (the store appends `share-outbox/`),
    /// or nil to simulate a missing App-Group container.
    public init(directoryURL: URL?) {
        self.directoryURL = directoryURL?.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    /// Atomic write to a unique filename; creates the directory on first use.
    public func write(_ capture: SharedCapture) throws {
        guard let dir = directoryURL else { throw ShareOutboxError.noContainer }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = IDGenerator.generate(size: IDGenerator.Size.task)
        let url = dir.appendingPathComponent("\(id).json")
        let data = try JSONEncoder().encode(capture)
        try data.write(to: url, options: .atomic)
    }

    /// All captures, sorted by `capturedAt`. Unreadable/corrupt files are skipped AND deleted
    /// (unrecoverable; prevents accumulation). Missing container ⇒ empty.
    public func pending() -> [(id: String, capture: SharedCapture)] {
        guard let dir = directoryURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var result: [(id: String, capture: SharedCapture)] = []
        for name in names where name.hasSuffix(".json") {
            let url = dir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let capture = try? JSONDecoder().decode(SharedCapture.self, from: data) else {
                try? FileManager.default.removeItem(at: url)   // corrupt → skip + delete
                continue
            }
            let id = String(name.dropLast(".json".count))
            result.append((id: id, capture: capture))
        }
        return result.sorted { $0.capture.capturedAt < $1.capture.capturedAt }
    }

    /// Delete one capture's file after a successful ingest. Best-effort (already-gone ⇒ no-op).
    public func remove(id: String) {
        guard let dir = directoryURL else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }
}

public enum ShareOutboxError: Error { case noContainer }
