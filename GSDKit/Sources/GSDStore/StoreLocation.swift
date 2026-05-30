import Foundation

/// Resolves the on-disk database location. Prefers the App Group container so
/// Phase 6 widgets/extensions share one store; falls back to Application Support
/// when the group is unavailable (e.g. a plain simulator run without the
/// entitlement). This is the single place the path is decided (increment spec §3.1).
public enum StoreLocation {
    public static let appGroupID = "group.dev.vinny.gsd"
    public static let databaseFileName = "gsd.sqlite"

    public static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL.appendingPathComponent(databaseFileName)
        }
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                             appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent(databaseFileName)
    }
}
