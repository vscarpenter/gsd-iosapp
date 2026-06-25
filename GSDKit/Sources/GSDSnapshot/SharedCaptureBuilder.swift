import Foundation
import GSDModel

/// Pure: maps any `SharedCapture` to a `Task` guaranteed to pass `TaskValidator.validate`
/// (spec §5). Free-form share input is sanitized, clamped, and normalized here so the drain
/// can treat validation failure as impossible.
public enum SharedCaptureBuilder {
    public static func task(from capture: SharedCapture, id: String, now: Date) -> Task {
        Task(
            id: id,
            title: clampedTitle(capture.title),
            description: description(from: capture.urls),
            urgent: capture.urgent,
            important: capture.important,
            createdAt: now,
            updatedAt: now,
            tags: normalizedTags(capture.tags)
        )
    }

    private static func clampedTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Review link below") }
        // A share that carried only a URL (e.g. Mac Catalyst, where Safari provides no page
        // title) arrives with the URL as the title — derive a readable title from it. iOS keeps
        // its real page title, which is not a URL and so passes through untouched.
        let derived = URLSanitizer.sanitize(trimmed) != nil ? URLTitle.derive(from: trimmed) : ""
        let title = derived.isEmpty ? trimmed : derived
        return String(title.prefix(FieldLimits.titleRange.upperBound))   // clamp to 80
    }

    private static func description(from urls: [String]) -> String {
        let valid = urls.compactMap { URLSanitizer.sanitize($0) }
        let joined = valid.joined(separator: "\n")
        return joined.count > FieldLimits.descriptionMax
            ? String(joined.prefix(FieldLimits.descriptionMax))            // clamp to 600
            : joined
    }

    /// The chips to show under a live "comma, separated" tags field. A token is *committed* (chipped)
    /// only once a comma follows it; the trailing token (no comma yet) is still being typed and is
    /// excluded. Normalized identically to `task(from:)`, so the preview never shows a tag that the
    /// save would silently drop.
    public static func committedTags(fromField field: String) -> [String] {
        let tokens = field.split(separator: ",").map(String.init)
        let committed = field.last == "," ? tokens : Array(tokens.dropLast())
        return normalizedTags(committed)
    }

    private static func normalizedTags(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let t = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard FieldLimits.tagLengthRange.contains(t.count) else { continue }  // drop empty / >30
            guard seen.insert(t).inserted else { continue }                       // dedupe, keep order
            result.append(t)
            if result.count == FieldLimits.maxTags { break }                      // cap at 20
        }
        return result
    }
}
