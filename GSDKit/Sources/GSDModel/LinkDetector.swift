import Foundation

/// Finds http/https URLs in free text so the editor can surface a captured or
/// typed link as a tappable element (design-spec 2026-06-24).
///
/// Security note — this is a native app with no `WKWebView`, so the web-security
/// terms "XSS" and "CSP header" have no surface here: SwiftUI renders no HTML and
/// serves no HTTP. The native-equivalent safety nets are what this type enforces:
///   1. Scheme allowlist — every detected substring is re-validated through
///      `URLSanitizer` (http/https only, no embedded credentials, length-capped),
///      the codebase's single source of truth for "safe URL". The only thing ever
///      handed to `openURL` is a vetted URL — never executed, only opened.
///   2. No spoofing — the caller renders the URL string as its own label, so the
///      visible text always equals the destination.
/// A literal Content-Security-Policy header belongs to the web client
/// (`gsdtaskmanager.com`), not this binary.
public enum LinkDetector {
    /// Detected http/https URLs in original order, de-duplicated. Anything that
    /// fails `URLSanitizer` (wrong scheme, credentials, oversize, bare `www.`) is
    /// dropped. Returns `[]` for empty input or no matches.
    public static func detect(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        var seen = Set<String>()
        var result: [URL] = []
        let fullRange = NSRange(text.startIndex..., in: text)

        detector.enumerateMatches(in: text, range: fullRange) { match, _, _ in
            guard let match, let range = Range(match.range, in: text) else { return }
            // Validate the matched substring itself (not NSDataDetector's normalized
            // URL) so the link's label equals its destination and bare-`www` text,
            // which has no explicit scheme, is conservatively left un-linked.
            guard let safe = URLSanitizer.sanitize(String(text[range])),
                  let url = URL(string: safe),
                  seen.insert(safe).inserted else { return }
            result.append(url)
        }
        return result
    }
}
