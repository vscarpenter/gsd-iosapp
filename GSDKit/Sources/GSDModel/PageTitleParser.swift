import Foundation

/// Extracts a page title from raw HTML for shared-link enrichment. Prefers the Open Graph
/// `og:title`, falls back to the `<title>` element; decodes common entities, collapses
/// whitespace, trims. Foundation-only and pure so it is fully unit-tested. Regex-based title
/// extraction is intentionally lightweight, not a full HTML parser.
public enum PageTitleParser {
    public static func parse(html: String) -> String? {
        let ogPatterns = [
            #"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']*)["']"#,
            #"<meta[^>]+content=["']([^"']*)["'][^>]+property=["']og:title["']"#,
        ]
        for pattern in ogPatterns {
            if let raw = firstGroup(in: html, pattern: pattern) {
                let title = clean(raw)
                if !title.isEmpty { return title }
            }
        }
        if let raw = firstGroup(in: html, pattern: #"<title[^>]*>([\s\S]*?)</title>"#) {
            let title = clean(raw)
            if !title.isEmpty { return title }
        }
        return nil
    }

    private static func firstGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func clean(_ raw: String) -> String {
        let decoded = decodeEntities(raw)
        let collapsed = decoded.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities = [
        "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
        "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
    ]

    private static func decodeEntities(_ s: String) -> String {
        var result = s
        for (entity, char) in namedEntities {
            result = result.replacingOccurrences(of: entity, with: char)
        }
        return decodeNumericEntities(result)
    }

    /// Replaces `&#123;` and `&#x1F4A9;` with their Unicode scalars (matches reversed so
    /// earlier replacements don't shift later ranges).
    private static func decodeNumericEntities(_ s: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) else { return s }
        var result = s
        let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
        for match in matches.reversed() {
            guard let full = Range(match.range, in: result),
                  let hexFlag = Range(match.range(at: 1), in: result),
                  let digits = Range(match.range(at: 2), in: result) else { continue }
            let isHex = !result[hexFlag].isEmpty
            guard let code = UInt32(result[digits], radix: isHex ? 16 : 10),
                  let scalar = Unicode.Scalar(code) else { continue }
            result.replaceSubrange(full, with: String(scalar))
        }
        return result
    }
}
