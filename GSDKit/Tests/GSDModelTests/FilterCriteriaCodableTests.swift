import Testing
import Foundation
@testable import GSDModel

struct FilterCriteriaCodableTests {
    // Mirror GSDStore's GSDJSON ms-truncating ISO-8601 strategy so the round-trip
    // exercises the SAME date coding the smartViews JSON column will use.
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer(); try c.encode(FilterCriteriaCodableTests.formatter().string(from: date))
        }
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = FilterCriteriaCodableTests.formatter().date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }()
    private func roundTrip(_ c: FilterCriteria) throws -> FilterCriteria {
        try decoder.decode(FilterCriteria.self, from: try encoder.encode(c))
    }
    // ms-clean dates (DatePicker .date values are midnight → ms-clean; no truncation loss).
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let end   = Date(timeIntervalSince1970: 1_700_604_800)

    @Test func defaultsRoundTrip() throws {
        let c = FilterCriteria()
        #expect(try roundTrip(c) == c)
    }
    @Test func fullyPopulatedRoundTrips() throws {
        let c = FilterCriteria(quadrants: [.urgentImportant, .notUrgentImportant], status: .active,
                               tags: ["home", "work"], dueDateRange: .init(start: start, end: end),
                               overdue: true, dueToday: true, dueThisWeek: true, noDueDate: true,
                               recurrence: [.daily, .weekly, .monthly], recentlyAdded: true,
                               recentlyCompleted: true, readyToWork: true, searchQuery: "milk")
        #expect(try roundTrip(c) == c)
    }
    @Test func openEndedRangeRoundTrips() throws {
        let c = FilterCriteria(status: .completed, dueDateRange: .init(start: start, end: nil))
        #expect(try roundTrip(c) == c)
    }
    @Test func statusEncodesAsStableString() throws {
        let json = String(decoding: try encoder.encode(FilterCriteria(status: .active)), as: UTF8.self)
        #expect(json.contains("\"status\":\"active\""))
    }
}
