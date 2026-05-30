import Foundation

/// Security-sensitive URL sanitizer for the capture parser (product spec §6.2).
/// Accepts only http/https with a real host, no embedded credentials, under the
/// length cap, with trailing sentence punctuation stripped. Returns nil if unsafe.
public enum URLSanitizer {
    public static let maxLength = 2048
    private static let trailingPunctuation: Set<Character> = [",", ";", ":", ".", "!", "?", ")"]

    public static func sanitize(_ candidate: String) -> String? {
        // Strip trailing sentence punctuation (may be several, e.g. ").").
        var trimmed = candidate
        while let last = trimmed.last, trailingPunctuation.contains(last) {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, trimmed.count < maxLength else { return nil }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }

        // Reject embedded credentials (user:pass@host).
        guard components.user == nil, components.password == nil else { return nil }

        return trimmed
    }
}
