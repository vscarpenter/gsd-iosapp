import Foundation

/// The last snapshot the watch received, kept in a file so the app and its widget draw it when
/// the iPhone is out of reach (spec 12). Writes are atomic so a widget never reads half a file.
public struct WatchSnapshotStore: Sendable {
    public static let fileName = "watch-snapshot.json"
    private let fileURL: URL?

    public init(directoryURL: URL?) {
        self.fileURL = directoryURL?.appendingPathComponent(Self.fileName)
    }

    public func write(_ snapshot: WatchSnapshot) throws {
        guard let fileURL else { throw WatchStoreError.noContainer }
        try JSONEncoder().encode(snapshot).write(to: fileURL, options: .atomic)
    }

    /// `nil` on first launch or a file that no longer decodes.
    public func read() -> WatchSnapshot? {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(WatchSnapshot.self, from: data)
    }
}
