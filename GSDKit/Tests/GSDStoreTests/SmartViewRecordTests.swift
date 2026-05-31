import Testing
import Foundation
import GSDModel
@testable import GSDStore

struct SmartViewRecordTests {
    @Test func recordRoundTripsToDomainAndBack() throws {
        let criteria = FilterCriteria(quadrants: [.urgentImportant], status: .active, tags: ["work"],
                                      dueThisWeek: true, recurrence: [.weekly], searchQuery: "report")
        let view = SmartView(id: "sv1", name: "My View", icon: "star",
                             criteria: criteria, isBuiltIn: false)
        let created = Date(timeIntervalSince1970: 1000)
        let updated = Date(timeIntervalSince1970: 2000)
        let record = try SmartViewRecord(view, createdAt: created, updatedAt: updated)
        #expect(record.isBuiltIn == false)
        #expect(record.id == "sv1")
        let back = try record.toDomain()
        #expect(back == view)
        #expect(back.criteria == criteria)
    }
}
