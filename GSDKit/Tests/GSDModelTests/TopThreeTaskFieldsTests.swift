import Testing
import Foundation
@testable import GSDModel

/// The two optional top three fields on `Task`: absent keys stay absent, and a bad pick never
/// costs the user the task (spec 3.5).
struct TopThreeTaskFieldsTests {
    private func decode(_ extra: String) throws -> Task {
        let json = """
        {"id":"t","title":"t","urgent":true,"important":true,
         "createdAt":"2026-10-01T00:00:00Z","updatedAt":"2026-10-01T00:00:00Z"\(extra)}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Task.self, from: Data(json.utf8))
    }

    @Test func aTaskWithoutTheFieldsDecodesUnpicked() throws {
        let task = try decode("")
        #expect(task.focusDate == nil)
        #expect(task.focusRank == nil)
    }

    @Test func aValidPickDecodes() throws {
        let task = try decode(#","focusDate":"2026-11-04","focusRank":2"#)
        #expect(task.focusDate == "2026-11-04")
        #expect(task.focusRank == 2)
    }

    @Test(arguments: [
        #","focusDate":"2026-11-04","focusRank":4"#,
        #","focusDate":"2026-11-04","focusRank":1.5"#,
        #","focusDate":"2026-02-30","focusRank":1"#,
        #","focusDate":"2026-11-04""#,
        #","focusRank":2"#,
        #","focusDate":7,"focusRank":"x""#,
    ])
    func anInvalidPickIsUnsetAndTheTaskIsKept(extra: String) throws {
        let task = try decode(extra)
        #expect(task.id == "t")
        #expect(task.focusDate == nil)
        #expect(task.focusRank == nil)
    }

    @Test func anUnpickedTaskEncodesNoFocusKeys() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(try decode(""))) as? [String: Any]
        #expect(object?["focusDate"] == nil)
        #expect(object?["focusRank"] == nil)
    }
}
