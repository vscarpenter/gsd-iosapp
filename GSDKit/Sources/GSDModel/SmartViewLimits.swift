import Foundation

/// Import bounds for custom smart views. Matches web `SCHEMA_LIMITS` and Android
/// `SmartViewLimits`; an imported view is untrusted input and is checked here before it can
/// be stored or synced.
public enum SmartViewLimits {
    public static let maxViews = 100
    public static let maxPinned = 5
    static let idLength = 1...128
    static let nameLength = 1...80
    static let maxIconLength = 64
    static let maxSearchLength = 600
    static let maxFilterTags = 200
    static let maxQuadrants = 4
    static let maxRecurrence = 4

    static func isWithinBounds(_ view: SmartViewWire) -> Bool {
        let c = view.criteria
        return idLength.contains(view.id.count)
            && nameLength.contains(view.name.count)
            && (view.icon?.count ?? 0) <= maxIconLength
            && c.searchQuery.count <= maxSearchLength
            && c.tags.count <= maxFilterTags
            && c.tags.allSatisfy { FieldLimits.tagLengthRange.contains($0.count) }
            && c.quadrants.count <= maxQuadrants
            && c.recurrence.count <= maxRecurrence
    }
}
