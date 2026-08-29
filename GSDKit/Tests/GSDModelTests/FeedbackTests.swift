import Foundation
import Testing
@testable import GSDModel

/// The iOS half of the cross-platform feedback contract (web `lib/feedback/`).
/// The exact-keys test is the load-bearing one: adding a payload field without
/// updating the disclosure becomes a failure here rather than a silent leak.
struct FeedbackTests {

    private func fullDraft() -> FeedbackDraft {
        FeedbackDraft(sentiment: .up,
                      category: .idea,
                      message: "  Loving the matrix.  ",
                      votes: ["calendar-sync", "apple-watch"])
    }

    private func build(_ draft: FeedbackDraft,
                       submissionID: String = "abc123",
                       appVersion: String = "ios-2.2.0.31",
                       submittedAt: Date = Date(timeIntervalSince1970: 0)) throws -> FeedbackPayload {
        try FeedbackPayloadBuilder.build(draft: draft,
                                         submissionID: submissionID,
                                         appVersion: appVersion,
                                         submittedAt: submittedAt)
    }

    // MARK: Wire shape

    @Test func payloadEncodesExactlyTheSevenWireKeys() throws {
        let payload = try build(fullDraft())
        let data = try JSONEncoder().encode(payload)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["submission_id", "sentiment", "category", "message",
                                     "votes", "app_version", "client_submitted_at"])
    }

    @Test func submittedAtEncodesAsISO8601WithMilliseconds() throws {
        let payload = try build(fullDraft(), submittedAt: Date(timeIntervalSince1970: 0))
        #expect(payload.clientSubmittedAt == "1970-01-01T00:00:00.000Z")
    }

    @Test func nilSentimentAndCategoryEncodeAsEmptyStrings() throws {
        var draft = fullDraft()
        draft.sentiment = nil
        draft.category = nil
        let payload = try build(draft)
        #expect(payload.sentiment == "")
        #expect(payload.category == "")
    }

    @Test func sentimentAndCategoryUseTheirRawWireValues() throws {
        let payload = try build(fullDraft())
        #expect(payload.sentiment == "up")
        #expect(payload.category == "idea")
    }

    // MARK: Votes

    @Test func unknownAndDuplicateVoteSlugsAreDropped() throws {
        var draft = fullDraft()
        draft.votes = ["calendar-sync", "calendar-sync", "not-a-slug", "apple-watch", "ios-widgets"]
        let payload = try build(draft)
        #expect(payload.votes == ["calendar-sync", "apple-watch"])
    }

    @Test func roadmapListMatchesTheCuratedSlugs() {
        #expect(Feedback.roadmapItems.map(\.slug) == [
            "natural-language-dates", "calendar-sync", "task-templates", "weekly-review",
            "focus-timer", "task-notes", "apple-watch", "shared-lists",
        ])
    }

    // MARK: Limits

    @Test func messageIsTrimmedAndKeptAtTheLimit() throws {
        var draft = fullDraft()
        draft.message = String(repeating: "x", count: Feedback.maxMessageLength)
        let payload = try build(draft)
        #expect(payload.message.count == Feedback.maxMessageLength)
        #expect(try build(fullDraft()).message == "Loving the matrix.")
    }

    @Test func messageOverTheLimitIsRefused() {
        var draft = fullDraft()
        draft.message = String(repeating: "x", count: Feedback.maxMessageLength + 1)
        #expect(throws: FeedbackError.messageTooLong) { _ = try build(draft) }
    }

    @Test func appVersionOverTwentyCharactersIsRefused() {
        #expect(throws: FeedbackError.appVersionTooLong) {
            _ = try build(fullDraft(), appVersion: String(repeating: "9", count: 21))
        }
    }

    @Test func emptySubmissionIDIsRefused() {
        #expect(throws: FeedbackError.submissionIDLength) {
            _ = try build(fullDraft(), submissionID: "")
        }
        #expect(throws: FeedbackError.submissionIDLength) {
            _ = try build(fullDraft(), submissionID: String(repeating: "a", count: 65))
        }
    }

    // MARK: Draft emptiness (gates the Send button)

    @Test func emptyDraftIsEmptyAndAnySingleFieldMakesItNot() {
        #expect(FeedbackDraft().isEmpty)
        #expect(FeedbackDraft(message: "   \n ").isEmpty)
        #expect(!FeedbackDraft(sentiment: .down).isEmpty)
        #expect(!FeedbackDraft(category: .bug).isEmpty)
        #expect(!FeedbackDraft(message: "hi").isEmpty)
        #expect(!FeedbackDraft(votes: ["focus-timer"]).isEmpty)
    }

    @Test func draftRoundTripsThroughJSON() throws {
        let draft = fullDraft()
        let decoded = try JSONDecoder().decode(FeedbackDraft.self,
                                               from: JSONEncoder().encode(draft))
        #expect(decoded == draft)
    }
}
