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
        return String(trimmed.prefix(FieldLimits.titleRange.upperBound))   // clamp to 80
    }

    private static func description(from urls: [String]) -> String {
        let valid = urls.compactMap { URLSanitizer.sanitize($0) }
        let joined = valid.joined(separator: "\n")
        return joined.count > FieldLimits.descriptionMax
            ? String(joined.prefix(FieldLimits.descriptionMax))            // clamp to 600
            : joined
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
