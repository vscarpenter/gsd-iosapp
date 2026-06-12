import Foundation
import GSDStore
import GSDSnapshot

extension Notification.Name {
    static let gsdOpenDeepLink = Notification.Name("dev.vinny.gsd.openDeepLink")
}

enum DeepLinkHandoff {
    private static let pendingURLKey = "pendingDeepLinkURL"

    @MainActor
    static func open(_ route: DeepLinkRoute) {
        open(route.url)
    }

    @MainActor
    static func open(_ url: URL) {
        AppGroupDefaults.shared.set(url.absoluteString, forKey: pendingURLKey)
        NotificationCenter.default.post(name: .gsdOpenDeepLink, object: url)
    }

    @MainActor
    static func consumePendingURL() -> URL? {
        guard let raw = AppGroupDefaults.shared.string(forKey: pendingURLKey),
              let url = URL(string: raw)
        else { return nil }
        AppGroupDefaults.shared.removeObject(forKey: pendingURLKey)
        return url
    }
}
