import Foundation

/// Pure ordered-pin rules (product spec §6.13): pinned views surface first, in pin
/// order, capped at `maxPins`. No persistence here — the store maps these over the
/// UserDefaults-backed `[String]` of pinned ids.
public enum SmartViewPinning {
    public static let maxPins = 5

    /// Append `id` if absent and under the cap; otherwise return `pins` unchanged.
    public static func pin(_ id: String, in pins: [String]) -> [String] {
        guard !pins.contains(id), pins.count < maxPins else { return pins }
        return pins + [id]
    }

    public static func unpin(_ id: String, in pins: [String]) -> [String] {
        pins.filter { $0 != id }
    }

    /// Reorder within the pinned list (drag-to-reorder). Mirrors `Array.move` semantics
    /// without importing SwiftUI (GSDStore stays SwiftUI-free).
    public static func reorder(_ pins: [String], fromOffsets: IndexSet, toOffset: Int) -> [String] {
        var copy = pins
        let moved = fromOffsets.sorted(by: >).map { idx -> String in
            let item = copy[idx]; copy.remove(at: idx); return item
        }.reversed()
        let shift = fromOffsets.filter { $0 < toOffset }.count
        copy.insert(contentsOf: moved, at: toOffset - shift)
        return copy
    }
}
