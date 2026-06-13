import Foundation
import GSDModel

/// App routes reachable via the `gsd://` scheme (spec §4.2 / §7).
public enum DeepLinkRoute: Equatable, Sendable {
    case focus
    case capture
    case quadrant(Quadrant)
    case task(String)
    case smartView(String)
    case dashboard
    case settings
    case archive

    public var url: URL {
        switch self {
        case .focus:
            URL(string: "gsd://focus")!
        case .capture:
            URL(string: "gsd://capture")!
        case .quadrant(let quadrant):
            URL(string: "gsd://quadrant/\(quadrant.rawValue)")!
        case .task(let id):
            URL(string: "gsd://task/\(encodePathSegment(id))")!
        case .smartView(let id):
            URL(string: "gsd://smart-view/\(encodePathSegment(id))")!
        case .dashboard:
            URL(string: "gsd://dashboard")!
        case .settings:
            URL(string: "gsd://settings")!
        case .archive:
            URL(string: "gsd://archive")!
        }
    }
}

public enum DeepLinkParser {
    /// Maps a `gsd://` URL to a route. Returns nil for anything we don't own —
    /// crucially `gsd://oauth-callback`, so a stray delivery to .onOpenURL is ignored.
    public static func route(from url: URL) -> DeepLinkRoute? {
        guard url.scheme == "gsd" else { return nil }
        switch url.host {
        case "focus":
            return .focus
        case "capture":
            return .capture
        case "quadrant":
            guard let value = firstPathComponent(url),
                  let quadrant = Quadrant(rawValue: value)
            else { return nil }
            return .quadrant(quadrant)
        case "task":
            guard let id = firstPathComponent(url), !id.isEmpty else { return nil }
            return .task(id)
        case "smart-view":
            guard let id = firstPathComponent(url), !id.isEmpty else { return nil }
            return .smartView(id)
        case "dashboard":
            return .dashboard
        case "settings":
            return .settings
        case "archive":
            return .archive
        default:
            return nil   // includes "oauth-callback"
        }
    }

    private static func firstPathComponent(_ url: URL) -> String? {
        // `pathComponents` already percent-decodes — decoding again would corrupt IDs
        // containing literal '%' sequences (the encode side performs exactly one encode).
        url.pathComponents.dropFirst().first
    }
}

/// Percent-encodes an ID so it survives as a SINGLE path segment: unlike `.urlPathAllowed`,
/// '/' is escaped (it would otherwise split the ID into multiple components).
private func encodePathSegment(_ id: String) -> String {
    id.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) ?? id
}

private let pathSegmentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
