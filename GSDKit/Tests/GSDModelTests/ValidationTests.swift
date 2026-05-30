import Testing
import Foundation
@testable import GSDModel

struct ValidationTests {
    private func makeTask(title: String) -> Task {
        Task(id: "v1", title: title, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    @Test func rejectsEmptyTitle() {
        #expect(throws: ValidationError.titleLength) {
            try TaskValidator.validate(makeTask(title: ""))
        }
    }

    @Test func rejectsTitleOver80Chars() {
        #expect(throws: ValidationError.titleLength) {
            try TaskValidator.validate(makeTask(title: String(repeating: "x", count: 81)))
        }
    }

    @Test func acceptsValidTitle() throws {
        try TaskValidator.validate(makeTask(title: "Buy milk"))
    }

    @Test func estimateOfZeroCoercesToUnset() {
        #expect(FieldLimits.normalizedEstimate(0) == nil)
        #expect(FieldLimits.normalizedEstimate(45) == 45)
    }

    @Test func rejectsTooManyTags() {
        var task = makeTask(title: "ok")
        task.tags = (0..<21).map { "tag\($0)" }
        #expect(throws: ValidationError.tooManyTags) {
            try TaskValidator.validate(task)
        }
    }
}
