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
            let tokens = stripExtension(slug)
                .replacingOccurrences(of: "_", with: "-")
                .split(separator: "-")
                .map(String.init)
                .filter { !$0.isEmpty }
            // Use the slug only when most tokens read like words — so an article slug becomes a
            // title, but an opaque id (UUID like "b6ef5e8a-4288-…", a number, or a hex blob) falls
            // back to the host. The check is the gate; once it passes, every token is kept.
            let wordLike = tokens.filter(isWordLike)
            if !wordLike.isEmpty, wordLike.count * 2 >= tokens.count {
                return tokens.map(capitalizeFirst).joined(separator: " ")
            }
        }

        if let host = url.host {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        return ""
    }

    /// A token reads like a word (vs. an opaque id): all letters and containing a vowel. IDs are
    /// excluded because they mix in digits ("a017", "4288") or lack vowels.
    private static func isWordLike(_ token: String) -> Bool {
        let vowels: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        return token.allSatisfy(\.isLetter) && token.lowercased().contains(where: vowels.contains)
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
