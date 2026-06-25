import Foundation

/// Derives a human-readable title from a URL — its last path segment ("slug") turned into
/// words, falling back to the host. Used when no real page title is available, e.g. a Mac
/// Catalyst share (where Safari hands the extension only the bare URL, no `document.title`).
/// Deliberately simple: an article slug like `…/my-great-post` becomes "My Great Post";
/// an id/number-only segment or an empty path falls back to the host.
public enum URLTitle {
    private static let webExtensions: Set<String> = ["html", "htm", "php", "asp", "aspx", "jsp"]

    public static func derive(from urlString: String) -> String {
        guard let url = URL(string: urlString) else { return "" }

        let segments = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        if let slug = segments.last {
            let title = stripExtension(slug)
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-")
                .map { capitalizeFirst(String($0)) }
                .joined(separator: " ")
            // A real title has letters; a bare id/number slug (e.g. "12345") falls to the host.
            if title.contains(where: \.isLetter) { return title }
        }

        if let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return ""
    }

    private static func stripExtension(_ segment: String) -> String {
        guard let dot = segment.lastIndex(of: "."),
              webExtensions.contains(segment[segment.index(after: dot)...].lowercased())
        else { return segment }
        return String(segment[..<dot])
    }

    private static func capitalizeFirst(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }
}
