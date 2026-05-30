import Foundation

enum AppGroup { static let id = "group.dev.vinny.gsd" }

extension UserDefaults {
    /// Shared App-Group defaults; falls back to `.standard` if the group is
    /// unavailable (e.g. a plain simulator run without the entitlement).
    nonisolated(unsafe) static let shared = UserDefaults(suiteName: AppGroup.id) ?? .standard
}
