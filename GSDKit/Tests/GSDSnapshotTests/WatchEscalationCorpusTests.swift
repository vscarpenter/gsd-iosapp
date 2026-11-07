import Testing
import Foundation
import GSDModel
import GSDSnapshot

/// Spec 9 test 5. Runs the shared escalation corpus (byte-identical copy of the web repo's
/// `escalation-corpus.json`, md5 731c71e9ed3fde49c5a44b35e7a617d0) through
/// `WatchTask` -> `Task`, to prove the mapping keeps every field escalation reads.
/// Cases the snapshot never carries (completed, Saved) must be left out by the builder.
struct WatchEscalationCorpusTests {
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

    @Test func everyCorpusCaseSurvivesTheWatchTaskMapping() throws {
        let url = try #require(Bundle.module.url(forResource: "escalation-corpus",
                                                 withExtension: "json", subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.count == 38)
        var mapped = 0
        for c in corpus.cases {
            let epoch = Date(timeIntervalSince1970: 0)
            let original = Task(
                id: "t", title: "t", urgent: c.task.urgent, important: c.task.important,
                completed: c.task.completed, createdAt: epoch, updatedAt: epoch,
                dueDate: try c.task.dueDate.map(Self.date),
                recurrence: c.task.recurrence.flatMap(RecurrenceType.init(rawValue:)) ?? .none,
                snoozedUntil: try c.task.snoozedUntil.map(Self.date),
                savedAt: try c.task.savedAt.map(Self.date))
            let zone = try #require(TimeZone(identifier: c.zone), "\(c.name) zone")
            let now = try Self.date(c.now)

            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let snap = WatchSnapshotBuilder.build(from: [original], now: now, calendar: calendar,
                                                  escalationWindowDays: c.windowDays, appliedCommandIDs: [])
            if original.completed || original.isSaved {
                #expect(snap.tasks.isEmpty, "\(c.name): completed or Saved rows never reach the watch")
                continue
            }
            // A not-urgent row with no due date, or one past the 7-day reach, isn't carried either;
            // the builder is not the rule under test, so map the row directly in that case.
            let watchTask = snap.tasks.first ?? WatchTask(original)
            let r = Escalation.evaluate(watchTask.asTask, now: now, windowDays: c.windowDays, timeZone: zone)
            #expect(r.escalating == c.expect.escalating, "\(c.name): escalating")
            #expect(r.daysUntilDue == c.expect.daysUntilDue, "\(c.name): daysUntilDue")
            #expect(r.reason?.rawValue == c.expect.reason, "\(c.name): reason")
            #expect(r.target?.rawValue == c.expect.target, "\(c.name): target")
            mapped += 1
        }
        #expect(mapped > 0)
    }
}
