import Foundation

/// App routes reachable via the `gsd://` scheme (spec §4.2 / §7).
public enum DeepLinkRoute: Equatable, Sendable {
    case focus
    public var url: URL { URL(string: "gsd://focus")! }
}

public enum DeepLinkParser {
    /// Maps a `gsd://` URL to a route. Returns nil for anything we don't own —
    /// crucially `gsd://oauth-callback`, so a stray delivery to .onOpenURL is ignored.
    public static func route(from url: URL) -> DeepLinkRoute? {
        guard url.scheme == "gsd" else { return nil }
        switch url.host {
        case "focus": return .focus
        default:      return nil   // includes "oauth-callback"
        }
    }
}
