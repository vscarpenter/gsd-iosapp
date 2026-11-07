import Foundation

/// The watch command ids the iPhone has already handled, newest last, capped at
/// `WatchSnapshot.appliedCommandCap`. It lives in App-Group `UserDefaults` so a relaunch does
/// not forget an id, and the same list goes to the watch in each snapshot so it can drop
/// pending commands the phone has taken.
public struct WatchAppliedLedger {
    static let key = "watchAppliedCommandIDs"

    private let defaults: UserDefaults
    public private(set) var ids: [String]

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.ids = defaults.stringArray(forKey: Self.key) ?? []
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func record(_ id: String) {
        guard !ids.contains(id) else { return }
        ids.append(id)
        if ids.count > WatchSnapshot.appliedCommandCap {
            ids.removeFirst(ids.count - WatchSnapshot.appliedCommandCap)
        }
        defaults.set(ids, forKey: Self.key)
    }
}
