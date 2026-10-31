import Foundation
import Testing
@testable import GSDModel

/// Runs the shared due-time corpus (decision D-1), a byte-identical copy of the web repo's
/// `tests/fixtures/cross-platform/due-time-corpus.json`. Every client runs every case.
struct DueTimeCorpusTests {
    private struct Corpus: Decodable { let cases: [Case] }

    private struct Case: Decodable {
        let name: String
        let op: String
        let zone: String
        let due: String?
        let date: String?
        let time: String?
        let now: String?
        let notifyBefore: Int?
        let defaultReminder: Int?
        let snoozedUntil: String?
        let quietHoursStart: String?
        let quietHoursEnd: String?
        let expect: Expect
    }

    private struct Expect: Decodable {
        let allDay: Bool?
        let localDate: String?
        let displayTime: String?
        let due: String?
        let fire: String?
    }

    private func isoFormatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }

    private func date(_ s: String?) throws -> Date? {
        guard let s else { return nil }
        return try #require(isoFormatter().date(from: s), "bad ISO date \(s)")
    }

    private func string(_ d: Date?) -> String? { d.map { isoFormatter().string(from: $0) } }

    private func dayComponents(_ s: String) -> DateComponents {
        let p = s.split(separator: "-").compactMap { Int($0) }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }

    private func hourMinute(_ s: String?) -> (hour: Int, minute: Int)? {
        guard let s else { return nil }
        let p = s.split(separator: ":").compactMap { Int($0) }
        return (p[0], p[1])
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try #require(TimeZone(identifier: zone), "unknown zone \(zone)")
        return cal
    }

    private func check(_ c: Case) throws {
        let cal = try calendar(c.zone)
        switch c.op {
        case "classify":
            let due = try #require(try date(c.due))
            let time = DueTime.time(of: due, calendar: cal)
            let display = time.map { String(format: "%02d:%02d", $0.hour, $0.minute) }
            let day = cal.dateComponents([.year, .month, .day], from: due)
            let local = String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
            #expect((time == nil) == c.expect.allDay, "\(c.name) — allDay")
            #expect(local == c.expect.localDate, "\(c.name) — localDate")
            #expect(display == c.expect.displayTime, "\(c.name) — displayTime")
        case "onDate":
            let result = DueTime.onDate(try date(c.due), to: dayComponents(c.date!), calendar: cal)
            #expect(string(result) == c.expect.due, "\(c.name)")
        case "atTime":
            let result = DueTime.atTime(try #require(try date(c.due)), hourMinute(c.time), calendar: cal)
            #expect(string(result) == c.expect.due, "\(c.name)")
        default:
            var task = Task(id: "t", title: "t", urgent: false, important: false,
                        createdAt: .distantPast, updatedAt: .distantPast)
            task.dueDate = try date(c.due)
            task.notifyBefore = c.notifyBefore
            task.snoozedUntil = try date(c.snoozedUntil)
            let inputs = ReminderMath.Inputs(masterEnabled: true, defaultReminder: c.defaultReminder ?? 15)
            let fire = ReminderMath.nextFire(for: task, inputs: inputs,
                                             quietStart: c.quietHoursStart, quietEnd: c.quietHoursEnd,
                                             now: try #require(try date(c.now)), calendar: cal)
            #expect(string(fire) == c.expect.fire, "\(c.name)")
        }
    }

    @Test func everyCorpusCaseAgrees() throws {
        let url = try #require(Bundle.module.url(forResource: "due-time-corpus",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.cases.count == 111)
        for c in corpus.cases { try check(c) }
    }
}
