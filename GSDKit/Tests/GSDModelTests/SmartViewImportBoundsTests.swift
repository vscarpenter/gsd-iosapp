import Testing
import Foundation
@testable import GSDModel

/// B-09: imported smart views are untrusted. Bounds match web `SCHEMA_LIMITS` and Android
/// `SmartViewLimits`; an out-of-bounds view is skipped and counted, never fails the import.
struct SmartViewImportBoundsTests {
    private let stamp = Date(timeIntervalSince1970: 0)

    private func view(id: String = "v1", name: String = "Mine", icon: String? = nil,
                      criteria: FilterCriteria = FilterCriteria(), isBuiltIn: Bool = false) -> SmartViewWire {
        SmartViewWire(id: id, name: name, icon: icon, criteria: criteria, isBuiltIn: isBuiltIn,
                      createdAt: stamp, updatedAt: stamp)
    }
    private func parse(_ views: [SmartViewWire], pins: [String]? = nil) throws -> ImportResult {
        let prefs = pins.map { AppPreferencesWire(pinnedSmartViewIds: $0, maxPinnedViews: 5) }
        let export = TaskExport(tasks: [], exportedAt: stamp, smartViews: views, appPreferences: prefs)
        return try TaskImporter.replace(from: TaskExport.encode(export))
    }

    @Test func wellFormedViewPasses() throws {
        let r = try parse([view()])
        #expect(r.smartViews?.map(\.id) == ["v1"])
        #expect(r.skipped == 0)
    }

    @Test func oversizedFieldsAreSkippedAndCounted() throws {
        let tags201 = (0..<201).map { "t\($0)" }
        let bad = [
            view(id: "a", name: String(repeating: "n", count: 81)),
            view(id: "b", name: ""),
            view(id: String(repeating: "i", count: 129), name: "x"),
            view(id: "c", icon: String(repeating: "i", count: 65)),
            view(id: "d", criteria: FilterCriteria(tags: tags201)),
            view(id: "e", criteria: FilterCriteria(tags: [String(repeating: "t", count: 31)])),
            view(id: "f", criteria: FilterCriteria(searchQuery: String(repeating: "q", count: 601))),
        ]
        let r = try parse(bad + [view(id: "ok")])
        #expect(r.smartViews?.map(\.id) == ["ok"])
        #expect(r.skipped == 7)
    }

    @Test func boundaryValuesPass() throws {
        let r = try parse([view(name: String(repeating: "n", count: 80),
                                criteria: FilterCriteria(tags: (0..<200).map { "t\($0)" },
                                                         searchQuery: String(repeating: "q", count: 600)))])
        #expect(r.skipped == 0)
    }

    @Test func atMostOneHundredCustomViewsAreAdmitted() throws {
        let views = (0..<103).map { view(id: "v\($0)") }
        let r = try parse(views)
        #expect(r.smartViews?.count == 100)
        #expect(r.skipped == 3)
    }

    @Test func builtInViewsDoNotCountTowardTheCap() throws {
        let r = try parse((0..<100).map { view(id: "v\($0)") } + [view(id: "builtin", isBuiltIn: true)])
        #expect(r.skipped == 0)
    }

    @Test func descriptionOverSixHundredIsSkipped() throws {
        var long = view(id: "long")
        long.description = String(repeating: "d", count: 601)
        var edge = view(id: "edge")
        edge.description = String(repeating: "d", count: 600)
        let r = try parse([long, edge])
        #expect(r.smartViews?.map(\.id) == ["edge"])
        #expect(r.skipped == 1)
    }

    @Test func pinToADroppedViewIsRemovedAndFreesItsSlot() throws {
        let dropped = view(id: "dropped", name: String(repeating: "n", count: 81))
        let r = try parse([view(id: "kept"), dropped], pins: ["dropped", "kept", "today-focus", "b", "c", "d"])
        // "dropped" has nothing behind it; built-in and not-in-file ids are left alone.
        #expect(r.pinnedSmartViewIds == ["kept", "today-focus", "b", "c", "d"])
    }

    @Test func pinnedIdsAreCappedAtFive() throws {
        let r = try parse([], pins: ["a", "b", "c", "d", "e", "f", "g"])
        #expect(r.pinnedSmartViewIds == ["a", "b", "c", "d", "e"])
    }
}
