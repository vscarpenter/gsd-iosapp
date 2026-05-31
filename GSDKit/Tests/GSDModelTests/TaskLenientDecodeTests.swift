import Testing
import Foundation
@testable import GSDModel

struct TaskLenientDecodeTests {
    /// Fractional-seconds ISO-8601 decoder (matches the export codec).
    private func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = f.date(from: s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date \(s)")
            }
            return date
        }
        return d
    }

    @Test func decodesLegacyTaskWithOnlyRequiredKeysFillingDefaults() throws {
        // Only the 6 required keys + a legacy unknown key; every defaulted field omitted.
        let json = """
        {"id":"ok","title":"Legacy","urgent":true,"important":false,
         "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z",
         "vectorClock":{"node":5}}
        """
        let t = try decoder().decode(Task.self, from: Data(json.utf8))
        #expect(t.id == "ok" && t.urgent == true && t.important == false)
        #expect(t.tags == [] && t.subtasks == [] && t.dependencies == [])     // defaulted
        #expect(t.completed == false && t.description == "")
        #expect(t.recurrence == .none)
        #expect(t.notificationEnabled == true)                                // non-false default preserved
        #expect(t.dueDate == nil && t.completedAt == nil && t.parentTaskId == nil)  // optionals → nil
    }
    @Test func throwsWhenRequiredFieldMissing() {
        let json = """
        {"id":"x","title":"No createdAt","urgent":false,"important":false,
         "updatedAt":"1970-01-01T00:00:00.000Z"}
        """
        #expect(throws: (any Error).self) { _ = try decoder().decode(Task.self, from: Data(json.utf8)) }
    }
    @Test func throwsOnWrongTypedRequiredField() {
        let json = """
        {"id":"bad","title":42,"urgent":true,"important":true,
         "createdAt":"1970-01-01T00:00:00.000Z","updatedAt":"1970-01-01T00:00:00.000Z"}
        """
        #expect(throws: (any Error).self) { _ = try decoder().decode(Task.self, from: Data(json.utf8)) }
    }
    @Test func encodeThenDecodeRoundTripsEqual() throws {
        let original = Task(id: "r", title: "Round", urgent: true, important: true,
                            createdAt: Date(timeIntervalSince1970: 0.5),
                            updatedAt: Date(timeIntervalSince1970: 0.5),
                            dueDate: Date(timeIntervalSince1970: 100), tags: ["a"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try c.encode(f.string(from: date))
        }
        let back = try decoder().decode(Task.self, from: try encoder.encode(original))
        #expect(back == original)
    }
}
