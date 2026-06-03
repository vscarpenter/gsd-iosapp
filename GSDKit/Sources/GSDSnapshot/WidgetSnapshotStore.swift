import Foundation
import GSDModel

/// Reads/writes the widget snapshot in the App-Group container (spec §4.2).
/// Writes are atomic (write-temp-then-rename) so the widget never reads a partial file.
public struct WidgetSnapshotStore: Sendable {
    public static let fileName = "widget-today-focus.json"
    private let containerURL: URL?

    /// Production: resolves the App-Group container (pure Foundation; GRDB-free).
    public init(appGroupID: String = AppGroup.id, fileManager: FileManager = .default) {
        self.containerURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Test seam: inject a temp directory (or nil to simulate a missing container).
    public init(containerURL: URL?) { self.containerURL = containerURL }

    private var fileURL: URL? { containerURL?.appendingPathComponent(Self.fileName) }

    public func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = fileURL else { throw WidgetSnapshotError.noContainer }
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Returns nil on missing/unreadable/corrupt — first launch and decode failures degrade to empty.
    public func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}

public enum WidgetSnapshotError: Error { case noContainer }
