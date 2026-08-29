import Foundation

/// Anonymous, opt-in feedback — the iOS half of the cross-platform contract
/// pinned by the web client's `lib/feedback/feedback-payload.ts` and the
/// PocketBase `feedback` collection.
///
/// `FeedbackPayloadBuilder.build` is pure — submission id, app version, and
/// timestamp are all injected — so the disclosure shown before Send renders
/// from the same output that is serialized into the request body; the two
/// cannot drift. Nothing here can read the task database, the sync config, or
/// the auth store: the builder sees only the draft and its options, which is
/// the privacy guarantee by construction.

public enum FeedbackSentiment: String, Codable, CaseIterable, Sendable {
    case up, down
}

public enum FeedbackCategory: String, Codable, CaseIterable, Sendable {
    case idea, praise, gripe, bug
}

/// A candidate feature users can vote for. Deliberately a hardcoded constant,
/// not a server-fetched list — drafting stays offline and the feedback
/// collection stays write-only from the client's point of view.
public struct RoadmapItem: Equatable, Sendable {
    /// Stable identifier sent in the payload. Never reuse a retired slug
    /// (`ios-widgets` is retired on iOS — the app ships widgets).
    public let slug: String
    public let label: String
    public let description: String

    public init(slug: String, label: String, description: String) {
        self.slug = slug
        self.label = label
        self.description = description
    }
}

public enum Feedback {
    /// Matches the web's `MAX_MESSAGE_LENGTH` and the collection schema.
    public static let maxMessageLength = 1000

    /// Wire limits from the collection schema (`submission_id` text 1–64,
    /// `app_version` text ≤20).
    public static let maxSubmissionIDLength = 64
    public static let maxAppVersionLength = 20

    /// The web's list with `ios-widgets` replaced by `apple-watch` — iOS
    /// already ships home-screen widgets. Slugs are shared with the web where
    /// the item is shared, so votes aggregate across clients.
    public static let roadmapItems: [RoadmapItem] = [
        RoadmapItem(slug: "natural-language-dates",
                    label: String(localized: "Natural-language due dates"),
                    description: String(localized: "Type “next tuesday 3pm” in the capture bar and have it understood.")),
        RoadmapItem(slug: "calendar-sync",
                    label: String(localized: "Two-way calendar sync"),
                    description: String(localized: "See scheduled tasks on your calendar, and calendar events in the matrix.")),
        RoadmapItem(slug: "task-templates",
                    label: String(localized: "Reusable task templates"),
                    description: String(localized: "Save a set of tasks you create repeatedly and drop them in with one action.")),
        RoadmapItem(slug: "weekly-review",
                    label: String(localized: "Guided weekly review"),
                    description: String(localized: "A short end-of-week pass over what moved, what stalled, and what to reclassify.")),
        RoadmapItem(slug: "focus-timer",
                    label: String(localized: "Focus timer"),
                    description: String(localized: "Start a timed run at a single task without leaving the matrix.")),
        RoadmapItem(slug: "task-notes",
                    label: String(localized: "Longer notes on a task"),
                    description: String(localized: "Room for context beyond a title — links, scratch thinking, and attachments.")),
        RoadmapItem(slug: "apple-watch",
                    label: String(localized: "Apple Watch app"),
                    description: String(localized: "Glance at Do First and check tasks off from your wrist.")),
        RoadmapItem(slug: "shared-lists",
                    label: String(localized: "Share one list with one person"),
                    description: String(localized: "A single shared quadrant for a partner or teammate, still local-first.")),
    ]

    private static let roadmapSlugs = Set(roadmapItems.map(\.slug))

    /// True when the slug is one this build actually ships. `build` filters
    /// stored votes through this, so a vote for a retired item is dropped
    /// rather than sent as an unknown value.
    public static func isRoadmapSlug(_ slug: String) -> Bool {
        roadmapSlugs.contains(slug)
    }
}

/// Local, unsent state. Persisted by the app layer only; never touches the
/// network until the user explicitly sends.
public struct FeedbackDraft: Codable, Equatable, Sendable {
    public var sentiment: FeedbackSentiment?
    public var category: FeedbackCategory?
    public var message: String
    public var votes: [String]

    public init(sentiment: FeedbackSentiment? = nil,
                category: FeedbackCategory? = nil,
                message: String = "",
                votes: [String] = []) {
        self.sentiment = sentiment
        self.category = category
        self.message = message
        self.votes = votes
    }

    /// True when there is nothing worth sending, so Send stays disabled.
    public var isEmpty: Bool {
        sentiment == nil
            && category == nil
            && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && votes.isEmpty
    }
}

/// The complete set of fields that leave the device — nothing else, pinned by
/// `FeedbackTests.payloadEncodesExactlyTheSevenWireKeys`. Optional sentiment
/// and category ride as `""`, matching the web payload byte-for-byte.
public struct FeedbackPayload: Codable, Equatable, Sendable {
    public let submissionID: String
    public let sentiment: String
    public let category: String
    public let message: String
    public let votes: [String]
    public let appVersion: String
    public let clientSubmittedAt: String

    private enum CodingKeys: String, CodingKey {
        case submissionID = "submission_id"
        case sentiment, category, message, votes
        case appVersion = "app_version"
        case clientSubmittedAt = "client_submitted_at"
    }
}

public enum FeedbackError: Error, Equatable {
    case messageTooLong
    case appVersionTooLong
    case submissionIDLength
}

public enum FeedbackPayloadBuilder {
    /// UTC with milliseconds — the shape `Date.toISOString()` writes on the web.
    /// Built per call: `ISO8601DateFormatter` is not `Sendable`, and this path
    /// runs once per send.
    private static func timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Build the outgoing payload from a draft. Throws only on an invariant
    /// break — the UI keeps the draft within limits, so a throw here is a bug,
    /// not user error.
    public static func build(draft: FeedbackDraft,
                             submissionID: String,
                             appVersion: String,
                             submittedAt: Date) throws -> FeedbackPayload {
        guard (1...Feedback.maxSubmissionIDLength).contains(submissionID.count) else {
            throw FeedbackError.submissionIDLength
        }
        guard appVersion.count <= Feedback.maxAppVersionLength else {
            throw FeedbackError.appVersionTooLong
        }
        let message = draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard message.count <= Feedback.maxMessageLength else {
            throw FeedbackError.messageTooLong
        }

        // Ordered dedup, then drop anything this build doesn't ship — same as
        // the web's `[...new Set(votes)].filter(isRoadmapSlug)`.
        var seen = Set<String>()
        let votes = draft.votes.filter { seen.insert($0).inserted && Feedback.isRoadmapSlug($0) }

        return FeedbackPayload(submissionID: submissionID,
                               sentiment: draft.sentiment?.rawValue ?? "",
                               category: draft.category?.rawValue ?? "",
                               message: message,
                               votes: votes,
                               appVersion: appVersion,
                               clientSubmittedAt: timestamp(from: submittedAt))
    }
}
