import Testing
import Foundation
@testable import GSDModel

/// Runs the shared cross-platform weekly sweep corpus: a byte-identical copy of the web repo's
/// `tests/fixtures/cross-platform/sweep-corpus.json` (md5 b10a904c5370f6da0ea4362badfd8743).
/// Web is the authority. If a case fails here, decide the correct behavior first, then change the
/// spec, the corpus, and all three implementations together.
struct SweepCorpusTests {
    private struct Corpus: Decodable { let version: Int; let cases: [Case] }

    private struct Case: Decodable {
        let name: String
        let op: String
        let zone: String
        let now: String
        let windowDays: Int?
        let tasks: [CaseTask]?
        let lastSweptAt: String?
        let cardCount: Int?
        let reminder: CaseReminder?
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
        var location: String?
    }

    private struct CaseReminder: Decodable { let enabled: Bool; let weekday: Int; let time: String }

    private struct Expected: Decodable {
        struct Card: Decodable { let id: String; let reason: String }
        let cards: [Card]?
        let shown: Bool?
        let fire: String?
    }

    private static func date(_ s: String) throws -> Date {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(fractional.date(from: s) ?? plain.date(from: s), "unparseable date \(s)")
    }

    private static func task(_ t: CaseTask) throws -> Task {
        let defaultStamp = try date("2026-11-07T00:00:00.000Z")
        return Task(
            id: t.id, title: t.id, urgent: t.urgent ?? false, important: t.important ?? false,
            completed: t.completed ?? false,
            createdAt: try t.createdAt.map(date) ?? defaultStamp,
            updatedAt: try t.updatedAt.map(date) ?? defaultStamp,
            dueDate: try t.dueDate.map(date),
            savedAt: try t.savedAt.map(date))
    }

    @Test func everyCorpusCaseBehavesIdentically() throws {
        let url = try #require(Bundle.module.url(forResource: "sweep-corpus",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.version == 1)
        #expect(corpus.cases.count == 74)
        for c in corpus.cases {
            let zone = try #require(TimeZone(identifier: c.zone), "\(c.name) zone")
            let now = try Self.date(c.now)
            switch c.op {
            case "cards":
                // `location` isn't a task field: archived and trashed rows live in their own stores.
                let tasks = try (c.tasks ?? []).filter { ($0.location ?? "active") == "active" }.map(Self.task)
                let cards = WeeklySweep.cards(tasks, now: now, windowDays: c.windowDays, timeZone: zone)
                #expect(cards.map(\.id) == c.expect.cards?.map(\.id), "\(c.name): ids")
                #expect(cards.map(\.reason.rawValue) == c.expect.cards?.map(\.reason), "\(c.name): reasons")
            case "entryShown":
                let shown = WeeklySweep.entryShown(lastSweptAt: try c.lastSweptAt.map(Self.date),
                                                   cardCount: c.cardCount ?? 0, now: now, timeZone: zone)
                #expect(shown == c.expect.shown, "\(c.name): shown")
            case "nextReminder":
                let r = try #require(c.reminder, "\(c.name) reminder")
                let parts = r.time.split(separator: ":").compactMap { Int($0) }
                let reminder = WeeklySweep.Reminder(enabled: r.enabled, weekday: r.weekday,
                                                    hour: parts[0], minute: parts[1])
                let fire = WeeklySweep.nextReminder(reminder, now: now, timeZone: zone)
                #expect(fire == (try c.expect.fire.map(Self.date)), "\(c.name): fire")
            default:
                Issue.record("\(c.name): unknown op \(c.op)")
            }
        }
    }
}
