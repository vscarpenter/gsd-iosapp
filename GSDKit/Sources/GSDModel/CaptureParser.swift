import Foundation

/// Result of parsing a capture string (product spec §6.2). The quadrant is
/// derived from `urgent`/`important` by the caller; a manual override (UI state)
/// can supersede the flags before a Task is built.
public struct ParsedCapture: Equatable, Sendable {
    public var title: String
    public var urgent: Bool
    public var important: Bool
    public var tags: [String]
    public var descriptionAdditions: [String]   // sanitized URLs to append to description
}

/// Parses the capture shorthand: `!!`/`!`/`*` flags, `#tag`s, and http(s) URLs.
/// Tokens are matched on word boundaries; `!!` takes precedence over `!`.
public enum CaptureParser {
    public static func parse(_ input: String) -> ParsedCapture {
        var working = input
        var urgent = false
        var important = false
        var tags: [String] = []
        var urls: [String] = []

        // 1. Extract URL-like words first (before token stripping mangles them).
        var remainingWords: [String] = []
        for word in working.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let token = String(word)
            if token.lowercased().hasPrefix("http://") || token.lowercased().hasPrefix("https://") {
                if let safe = URLSanitizer.sanitize(token) {
                    if !urls.contains(safe) { urls.append(safe) }
                    continue   // drop the URL word from the title
                }
            }
            remainingWords.append(token)
        }
        working = remainingWords.joined(separator: " ")

        // 2. Tags: #tag on word boundaries, lowercased, deduped, capped at 20.
        // NOTE: extended-delimiter regex literals (#/.../#) are REQUIRED — bare
        // /.../ literals hit Swift's operator-ambiguity parse error on `+`/`*`
        // (e.g. /\s+/ fails with "'+/' is not an operator"). Verified by probe.
        let tagMatches = working.matches(of: #/(?:^|\s)#(\w[\w-]*)/#)
        for match in tagMatches {
            let tag = String(match.1).lowercased()
            if !tags.contains(tag) && tags.count < FieldLimits.maxTags {
                tags.append(tag)
            }
        }
        working = working.replacing(#/(?:^|\s)#\w[\w-]*/#, with: "")

        // 3. Flags on word boundaries. `!!` before `!`.
        if working.contains(#/(?:^|\s)!!(?:\s|$)/#) { urgent = true; important = true }
        else if working.contains(#/(?:^|\s)!(?:\s|$)/#) { urgent = true }
        if working.contains(#/(?:^|\s)\*(?:\s|$)/#) { important = true }
        working = working.replacing(#/(?:^|\s)(?:!!|!|\*)(?=\s|$)/#, with: "")

        // 4. Collapse whitespace.
        var title = working.replacing(#/\s+/#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)

        // 5. Empty-title-with-URL fallback.
        if title.isEmpty && !urls.isEmpty {
            title = String(localized: "Review link below")
        }

        return ParsedCapture(title: title, urgent: urgent, important: important,
                             tags: tags, descriptionAdditions: urls)
    }
}
