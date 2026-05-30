import Testing
import Foundation
@testable import GSDModel

struct EmbeddedTypesTests {
    @Test func subtaskEncodesAndDecodesRoundTrip() throws {
        let subtask = Subtask(id: "abcd", title: "Draft outline", completed: false)
        let data = try JSONEncoder().encode(subtask)
        let decoded = try JSONDecoder().decode(Subtask.self, from: data)
        #expect(decoded == subtask)
    }

    @Test func timeEntryAllowsNilEndedAtAndNotes() throws {
        let entry = TimeEntry(id: "ab123456", startedAt: Date(timeIntervalSince1970: 0),
                              endedAt: nil, notes: nil)
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(TimeEntry.self, from: data)
        #expect(decoded == entry)
        #expect(decoded.endedAt == nil)
    }
}
