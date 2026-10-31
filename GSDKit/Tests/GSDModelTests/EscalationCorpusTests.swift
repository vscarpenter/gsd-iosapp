import Testing
import Foundation
@testable import GSDModel

/// Runs the shared cross-platform escalation corpus: a byte-identical copy of the web
/// repo's `tests/fixtures/cross-platform/escalation-corpus.json` (md5
/// 731c71e9ed3fde49c5a44b35e7a617d0). Web is the authority. If a case fails here, decide
/// the correct behavior first, then change the corpus and all three implementations together.
struct EscalationCorpusTests {
    private struct Corpus: Decodable { let version: Int; let cases: [Case] }
    private struct Case: Decodable {
        let name: String
        let zone: String
        let now: String
        let windowDays: Int?
        let task: CaseTask
        let expect: Expected
    }
    private struct CaseTask: Decodable {
        var urgent = false
        var important = false
        var completed = false
        var savedAt: String?
        var dueDate: String?
        var recurrence: String?
        var snoozedUntil: String?
    }
    private struct Expected: Decodable {
        let escalating: Bool
        let daysUntilDue: Int?
        let reason: String?
        let target: String?
    }

    private static func date(_ s: String) throws -> Date {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(fractional.date(from: s) ?? plain.date(from: s), "unparseable date \(s)")
    }

    @Test func everyCorpusCaseEvaluatesIdentically() throws {
        let url = try #require(Bundle.module.url(forResource: "escalation-corpus",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.version == 1)
        #expect(corpus.cases.count == 38)
        for c in corpus.cases {
            let epoch = Date(timeIntervalSince1970: 0)
            let task = Task(
                id: "t", title: "t",
                urgent: c.task.urgent, important: c.task.important,
                completed: c.task.completed,
                createdAt: epoch, updatedAt: epoch,
                dueDate: try c.task.dueDate.map(Self.date),
                recurrence: c.task.recurrence.flatMap(RecurrenceType.init(rawValue:)) ?? .none,
                snoozedUntil: try c.task.snoozedUntil.map(Self.date),
                savedAt: try c.task.savedAt.map(Self.date))
            let zone = try #require(TimeZone(identifier: c.zone), "\(c.name) zone")
            let r = Escalation.evaluate(task, now: try Self.date(c.now),
                                        windowDays: c.windowDays, timeZone: zone)
            #expect(r.escalating == c.expect.escalating, "\(c.name): escalating")
            #expect(r.daysUntilDue == c.expect.daysUntilDue, "\(c.name): daysUntilDue")
            #expect(r.reason?.rawValue == c.expect.reason, "\(c.name): reason")
            #expect(r.target?.rawValue == c.expect.target, "\(c.name): target")
        }
    }
}
