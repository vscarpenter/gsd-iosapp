import Testing
import Foundation
import GSDModel
import GSDSnapshot

/// Spec 9 test 5, phase 4 half. Runs the `picks` and `suggest` cases of the shared top three
/// corpus (a byte-identical copy of the web repo's `top-three-corpus.json`, md5
/// 074580772892c97fadaecd76e777a791) through the real path the watch uses: iPhone tasks, then
/// `WatchSnapshotBuilder`, then `WatchTask.asTask`, then `TopThree`. The mapping must keep every
/// field the two rules read, and the builder must carry every row they can return.
struct WatchTopThreeCorpusTests {
    private struct Corpus: Decodable { let version: Int; let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let op: String
        let zone: String?
        let now: String?
        let windowDays: Int?
        let tasks: [CaseTask]?
        let expect: Expected
    }
    private struct CaseTask: Decodable {
        var id: String
        var urgent: Bool?
        var important: Bool?
        var completed: Bool?
        var savedAt: String?
        var dueDate: String?
        var createdAt: String?
        var updatedAt: String?
        var focusDate: String?
        var focusRank: Double?
        var location: String?
    }
    private struct Expected: Decodable { let picks: [String]?; let overflow: [String]?; let ids: [String]? }

    private static func date(_ s: String) throws -> Date {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(fractional.date(from: s) ?? plain.date(from: s), "unparseable date \(s)")
    }

    private static func task(_ t: CaseTask) throws -> Task {
        let stamp = try date("2026-10-01T00:00:00.000Z")
        return Task(id: t.id, title: t.id, urgent: t.urgent ?? false, important: t.important ?? false,
                    completed: t.completed ?? false,
                    createdAt: try t.createdAt.map(date) ?? stamp, updatedAt: try t.updatedAt.map(date) ?? stamp,
                    dueDate: try t.dueDate.map(date), savedAt: try t.savedAt.map(date),
                    focusDate: t.focusDate, focusRank: t.focusRank.map { Int(exactly: $0) ?? 0 })
    }

    @Test func picksAndSuggestionsMatchTheCorpusAfterTheWatchMapping() throws {
        let url = try #require(Bundle.module.url(forResource: "top-three-corpus",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.count == 123)
        var checked = 0
        for c in corpus.cases where c.op == "picks" || c.op == "suggest" {
            let zone = try #require(TimeZone(identifier: c.zone ?? "GMT"), "\(c.name) zone")
            let now = try c.now.map(Self.date) ?? Date(timeIntervalSince1970: 0)
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            // Archived and trashed rows live in their own stores; completed and Saved rows never reach the watch.
            let active = try (c.tasks ?? []).filter { ($0.location ?? "active") == "active" }.map(Self.task)
                .filter { !$0.completed && !$0.isSaved }
            let snapshot = WatchSnapshotBuilder.build(from: active, now: now, calendar: calendar,
                                                      escalationWindowDays: c.windowDays, appliedCommandIDs: [])
            let mapped = snapshot.tasks.map(\.asTask)
            if c.op == "picks" {
                let r = TopThree.todaysPicks(mapped, now: now, timeZone: zone)
                #expect(r.picks == c.expect.picks, "\(c.name): picks")
                #expect(r.overflow == c.expect.overflow, "\(c.name): overflow")
            } else {
                let ids = TopThree.suggest(mapped, now: now, windowDays: c.windowDays, timeZone: zone)
                #expect(ids == c.expect.ids, "\(c.name): ids")
            }
            checked += 1
        }
        #expect(checked == 54)
    }
}
