import Testing
import Foundation
@testable import GSDModel

/// Runs the shared cross-platform top three corpus: a byte-identical copy of the web repo's
/// `tests/fixtures/cross-platform/top-three-corpus.json` (md5 074580772892c97fadaecd76e777a791).
/// Web is the authority. If a case fails here, decide the correct behavior first, then change the
/// spec, the corpus, and all three implementations together.
struct TopThreeCorpusTests {
    private struct Corpus: Decodable { let version: Int; let cases: [Case] }

    private struct Case: Decodable {
        let name: String
        let op: String
        let zone: String?
        let now: String?
        let windowDays: Int?
        let tasks: [CaseTask]?
        let wire: Wire?
        let task: Focus?
        let payload: Focus?
        let current: Focus?
        let storedContract: Int?
        let tombstoned: Bool?
        let local: SyncCaseRow?
        let remote: SyncCaseRow?
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

    private struct Wire: Decodable { let focus_date: String?; let focus_rank: Double? }
    private struct Focus: Decodable { let focusDate: String?; let focusRank: Int? }
    private struct SyncCaseRow: Decodable, Equatable {
        let updatedAt: String
        let focusDate: String?
        let focusRank: Int?
        let savedAt: String?
    }

    private struct Expected: Decodable {
        let picks: [String]?
        let overflow: [String]?
        let needsTidy: Bool?
        let ids: [String]?
        let rank: Int??
        let fromDate: String??
        let writes: [Write]?
        let focusDate: String??
        let focusRank: Int??
        let focus_date: String?
        let focus_rank: Int?
        let omit: Bool?
        let action: String?
        let conflict: Bool?
        let row: SyncCaseRow??

        struct Write: Decodable { let id: String; let focusDate: String?; let focusRank: Int? }

        // `rank: null` must stay distinct from an absent key, so decode those by hand.
        private enum Keys: String, CodingKey {
            case picks, overflow, needsTidy, ids, rank, fromDate, writes, focusDate, focusRank
            case focus_date, focus_rank, omit, action, conflict, row
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            picks = try c.decodeIfPresent([String].self, forKey: .picks)
            overflow = try c.decodeIfPresent([String].self, forKey: .overflow)
            needsTidy = try c.decodeIfPresent(Bool.self, forKey: .needsTidy)
            ids = try c.decodeIfPresent([String].self, forKey: .ids)
            rank = c.contains(.rank) ? .some(try c.decodeIfPresent(Int.self, forKey: .rank)) : nil
            fromDate = c.contains(.fromDate) ? .some(try c.decodeIfPresent(String.self, forKey: .fromDate)) : nil
            writes = try c.decodeIfPresent([Write].self, forKey: .writes)
            focusDate = c.contains(.focusDate) ? .some(try c.decodeIfPresent(String.self, forKey: .focusDate)) : nil
            focusRank = c.contains(.focusRank) ? .some(try c.decodeIfPresent(Int.self, forKey: .focusRank)) : nil
            focus_date = try c.decodeIfPresent(String.self, forKey: .focus_date)
            focus_rank = try c.decodeIfPresent(Int.self, forKey: .focus_rank)
            omit = try c.decodeIfPresent(Bool.self, forKey: .omit)
            action = try c.decodeIfPresent(String.self, forKey: .action)
            conflict = try c.decodeIfPresent(Bool.self, forKey: .conflict)
            row = c.contains(.row) ? .some(try c.decodeIfPresent(SyncCaseRow.self, forKey: .row)) : nil
        }
    }

    private static func date(_ s: String) throws -> Date {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try #require(fractional.date(from: s) ?? plain.date(from: s), "unparseable date \(s)")
    }

    /// A corpus task with the model's defaults for every field it leaves out. A non-integer rank
    /// cannot live in `Int?`, so it becomes an out-of-range rank, which is just as invalid.
    private static func task(_ t: CaseTask) throws -> Task {
        let defaultStamp = try date("2026-10-01T00:00:00.000Z")
        return Task(
            id: t.id, title: t.id, urgent: t.urgent ?? false, important: t.important ?? false, completed: t.completed ?? false,
            createdAt: try t.createdAt.map(date) ?? defaultStamp,
            updatedAt: try t.updatedAt.map(date) ?? defaultStamp,
            dueDate: try t.dueDate.map(date),
            savedAt: try t.savedAt.map(date),
            focusDate: t.focusDate,
            focusRank: t.focusRank.map { Int(exactly: $0) ?? 0 })
    }

    /// `location` isn't a task field: archived and trashed rows live in their own stores, so the
    /// test keeps only active rows, as the corpus note says.
    private static func activeTasks(_ c: Case) throws -> [Task] {
        try (c.tasks ?? []).filter { ($0.location ?? "active") == "active" }.map(task)
    }

    private static func syncRow(_ r: SyncCaseRow) throws -> TopThree.SyncRow {
        TopThree.SyncRow(updatedAt: try date(r.updatedAt), focusDate: r.focusDate, focusRank: r.focusRank,
                         savedAt: try r.savedAt.map(date))
    }

    @Test func everyCorpusCaseBehavesIdentically() throws {
        let url = try #require(Bundle.module.url(forResource: "top-three-corpus",
                                                 withExtension: "json",
                                                 subdirectory: "Fixtures"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.version == 1)
        #expect(corpus.cases.count == 123)
        for c in corpus.cases {
            try run(c)
        }
    }

    private func run(_ c: Case) throws {
        let name = c.name
        let zone = try c.zone.map { try #require(TimeZone(identifier: $0), "\(name) zone") } ?? .gmt
        let now = try c.now.map(Self.date) ?? Date(timeIntervalSince1970: 0)
        switch c.op {
        case "picks":
            let r = TopThree.todaysPicks(try Self.activeTasks(c), now: now, timeZone: zone)
            #expect(r.picks == c.expect.picks, "\(name): picks")
            #expect(r.overflow == c.expect.overflow, "\(name): overflow")
            #expect(r.needsTidy == c.expect.needsTidy, "\(name): needsTidy")
        case "nextRank":
            let r = TopThree.nextRank(try Self.activeTasks(c), now: now, timeZone: zone)
            #expect(r == c.expect.rank ?? nil, "\(name): rank")
        case "tidy":
            let writes = TopThree.tidy(try Self.activeTasks(c), now: now, timeZone: zone)
            let expected = c.expect.writes ?? []
            #expect(writes.map(\.id) == expected.map(\.id), "\(name): ids")
            #expect(writes.map(\.focusDate) == expected.map(\.focusDate), "\(name): dates")
            #expect(writes.map(\.focusRank) == expected.map(\.focusRank), "\(name): ranks")
        case "suggest":
            let ids = TopThree.suggest(try Self.activeTasks(c), now: now, windowDays: c.windowDays, timeZone: zone)
            #expect(ids == c.expect.ids, "\(name): ids")
        case "carryOver":
            let r = TopThree.carryOver(try Self.activeTasks(c), now: now, timeZone: zone)
            #expect(r.fromDate == c.expect.fromDate ?? nil, "\(name): fromDate")
            #expect(r.ids == c.expect.ids, "\(name): ids")
        case "fromWire":
            let w = try #require(c.wire, "\(name) wire")
            let r = TopThree.fromWire(focusDate: w.focus_date, focusRank: w.focus_rank)
            #expect(r.focusDate == c.expect.focusDate ?? nil, "\(name): focusDate")
            #expect(r.focusRank == c.expect.focusRank ?? nil, "\(name): focusRank")
        case "toWire":
            let t = try #require(c.task, "\(name) task")
            let r = TopThree.toWire(focusDate: t.focusDate, focusRank: t.focusRank)
            #expect(r.focusDate == c.expect.focus_date, "\(name): focus_date")
            #expect(r.focusRank == c.expect.focus_rank, "\(name): focus_rank")
        case "pushFocus":
            let p = try #require(c.payload, "\(name) payload")
            let r = TopThree.pushFocus(payload: (p.focusDate, p.focusRank),
                                       current: c.current.map { ($0.focusDate, $0.focusRank) })
            if c.expect.omit == true {
                #expect(r == nil, "\(name): omit")
            } else {
                #expect(r?.focusDate == c.expect.focus_date, "\(name): focus_date")
                #expect(r?.focusRank == c.expect.focus_rank, "\(name): focus_rank")
            }
        case "pullMerge":
            let r = TopThree.pullMerge(storedContract: c.storedContract,
                                       tombstoned: c.tombstoned ?? false,
                                       local: try c.local.map(Self.syncRow),
                                       remote: try Self.syncRow(try #require(c.remote, "\(name) remote")))
            #expect(r.action.rawValue == c.expect.action, "\(name): action")
            #expect(r.conflict == c.expect.conflict, "\(name): conflict")
            #expect(r.row == (try (c.expect.row ?? nil).map(Self.syncRow)), "\(name): row")
        default:
            Issue.record("\(name): unknown op \(c.op)")
        }
    }
}
