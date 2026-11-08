import Foundation

/// The WatchConnectivity payload keys, in one place so the iPhone and the watch can't drift.
public enum WatchWire {
    public static let snapshotKey = "snapshot"
    public static let commandKey = "command"

    public static func userInfo(for command: WatchCommand) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(command) else { return nil }
        return [commandKey: data]
    }

    public static func command(from userInfo: [String: Any]) -> WatchCommand? {
        guard let data = userInfo[commandKey] as? Data else { return nil }
        return try? JSONDecoder().decode(WatchCommand.self, from: data)
    }
}
