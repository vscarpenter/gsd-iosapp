import Foundation

/// The watch command ids the iPhone has already handled, newest last. It remembers the newest
/// 200 (spec 6.3) so a late repeat of a capture is still skipped; each snapshot carries only the
/// newest `WatchSnapshot.appliedCommandCap`. It lives in App-Group `UserDefaults` so a relaunch does
/// not forget an id, and the same list goes to the watch in each snapshot so it can drop
/// pending commands the phone has taken.
public struct WatchAppliedLedger {
    static let key = "watchAppliedCommandIDs"
    public static let capacity = 200

    private let defaults: UserDefaults
    public private(set) var ids: [String]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.ids = defaults.stringArray(forKey: Self.key) ?? []
    }

    /// The ids to send the watch.
    public var snapshotIDs: [String] { Array(ids.suffix(WatchSnapshot.appliedCommandCap)) }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func record(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > Self.capacity {
            ids.removeFirst(ids.count - Self.capacity)
        }
        defaults.set(ids, forKey: Self.key)
    }
}
