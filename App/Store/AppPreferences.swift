import Foundation
import GSDStore

extension UserDefaults {
    /// Shared App-Group defaults, through the store's one resolver: the App Group suite in a real
    /// launch, an empty per-launch suite in a harness launch (`HarnessLaunch.isIsolated`).
    nonisolated(unsafe) static let shared = AppGroupDefaults.shared
}
