import Testing
import Foundation
@testable import GSDModel

struct ValidationTests {
    private func makeTask(title: String) -> Task {
        Task(id: "v1", title: title, urgent: false, important: false,
             createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    // MARK: - Title

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

    // MARK: - Description

    @Test func rejectsDescriptionOver600Chars() {
        var task = makeTask(title: "ok")
        task.description = String(repeating: "a", count: 601)
        #expect(throws: ValidationError.descriptionTooLong) {
            try TaskValidator.validate(task)
        }
    }

    @Test func accepts600CharDescription() throws {
        var task = makeTask(title: "ok")
        task.description = String(repeating: "a", count: 600)
        try TaskValidator.validate(task)
    }

    // MARK: - Tags

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

    @Test func rejects31CharTag() {
        var task = makeTask(title: "ok")
        task.tags = [String(repeating: "t", count: 31)]
        #expect(throws: ValidationError.tagLength) {
            try TaskValidator.validate(task)
        }
    }

    @Test func rejectsEmptyTag() {
        var task = makeTask(title: "ok")
        task.tags = [""]
        #expect(throws: ValidationError.tagLength) {
            try TaskValidator.validate(task)
        }
    }

    // MARK: - Subtasks

    @Test func rejectsSubtaskWithTitleOver100Chars() {
        var task = makeTask(title: "ok")
        task.subtasks = [Subtask(id: "s1", title: String(repeating: "x", count: 101))]
        #expect(throws: ValidationError.subtaskTitleLength) {
            try TaskValidator.validate(task)
        }
    }

    @Test func rejectsSubtaskWithEmptyTitle() {
        var task = makeTask(title: "ok")
        task.subtasks = [Subtask(id: "s1", title: "")]
        #expect(throws: ValidationError.subtaskTitleLength) {
            try TaskValidator.validate(task)
        }
    }

    @Test func rejects51Subtasks() {
        var task = makeTask(title: "ok")
        task.subtasks = (0..<51).map { Subtask(id: "s\($0)", title: "subtask \($0)") }
        #expect(throws: ValidationError.tooManySubtasks) {
            try TaskValidator.validate(task)
        }
    }

    @Test func accepts50Subtasks() throws {
        var task = makeTask(title: "ok")
        task.subtasks = (0..<50).map { Subtask(id: "s\($0)", title: "subtask \($0)") }
        try TaskValidator.validate(task)
    }

    // MARK: - Dependencies

    @Test func rejects51Dependencies() {
        var task = makeTask(title: "ok")
        task.dependencies = (0..<51).map { "dep\($0)" }
        #expect(throws: ValidationError.tooManyDependencies) {
            try TaskValidator.validate(task)
        }
    }

    @Test func accepts50Dependencies() throws {
        var task = makeTask(title: "ok")
        task.dependencies = (0..<50).map { "dep\($0)" }
        try TaskValidator.validate(task)
    }

    // MARK: - Time Entries

    @Test func rejects1001TimeEntries() {
        var task = makeTask(title: "ok")
        let base = Date(timeIntervalSince1970: 0)
        task.timeEntries = (0..<1001).map { TimeEntry(id: "te\($0)", startedAt: base) }
        #expect(throws: ValidationError.tooManyTimeEntries) {
            try TaskValidator.validate(task)
        }
    }

    // MARK: - Estimate

    @Test func rejectsEstimateOver10080() {
        var task = makeTask(title: "ok")
        task.estimatedMinutes = 10081
        #expect(throws: ValidationError.estimateOutOfRange) {
            try TaskValidator.validate(task)
        }
    }

    @Test func acceptsEstimateOfZero() throws {
        // 0 means "unset" (product spec §5.1) — validator skips it entirely
        var task = makeTask(title: "ok")
        task.estimatedMinutes = 0
        try TaskValidator.validate(task)
    }

    @Test func acceptsEstimateOf1() throws {
        var task = makeTask(title: "ok")
        task.estimatedMinutes = 1
        try TaskValidator.validate(task)
    }

    @Test func acceptsEstimateOf10080() throws {
        var task = makeTask(title: "ok")
        task.estimatedMinutes = 10080
        try TaskValidator.validate(task)
    }

    // MARK: - ValidationError.message

    @Test func everyValidationErrorHasANonEmptyMessage() {
        let all: [ValidationError] = [.titleLength, .descriptionTooLong, .tagLength, .tooManyTags,
                                      .subtaskTitleLength, .tooManySubtasks, .tooManyDependencies,
                                      .estimateOutOfRange, .tooManyTimeEntries]
        for e in all { #expect(!e.message.isEmpty) }
    }

    @Test func descriptionErrorMessageMentionsDescription() {
        #expect(ValidationError.descriptionTooLong.message.localizedCaseInsensitiveContains("description"))
    }

    // MARK: - Happy path (fully-populated valid task)

    @Test func acceptsFullyPopulatedValidTask() throws {
        let base = Date(timeIntervalSince1970: 0)
        var task = makeTask(title: String(repeating: "x", count: 80))
        task.description = String(repeating: "d", count: 600)
        task.tags = (0..<20).map { "tag\($0)" }
        task.subtasks = (0..<50).map { Subtask(id: "s\($0)", title: "subtask \($0)") }
        task.dependencies = (0..<50).map { "dep\($0)" }
        task.timeEntries = (0..<1000).map { TimeEntry(id: "te\($0)", startedAt: base) }
        task.estimatedMinutes = 10080
        try TaskValidator.validate(task)
    }
}
