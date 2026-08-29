import Foundation
import GSDModel

/// How a feedback submission ended. Never an exception at the UI: the caller
/// is a form with the user's writing in it, so every failure comes back as a
/// reason it can show next to a retry button.
public enum FeedbackSubmitOutcome: Equatable, Sendable {
    case sent
    case offline
    case rateLimited
    case rejected
    case serverError
}

/// The one network call the feedback feature makes (mirrors the web's
/// `lib/feedback/submit-feedback.ts`).
///
/// Deliberately a bare executor over `URLSession`, never `PocketBaseClient`'s
/// authed helpers: this path's whole premise is anonymity, so no Authorization
/// header may ever be attached. `FeedbackClientTests` asserts the header's
/// absence rather than assuming it.
public struct FeedbackClient: Sendable {
    private static let feedbackPath = "/api/collections/feedback/records"

    private let baseURL: String
    private let executor: RequestExecuting

    public init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.executor = URLSessionExecutor(session: session)
    }

    init(baseURL: String, executor: RequestExecuting) {
        self.baseURL = baseURL
        self.executor = executor
    }

    public func submit(_ payload: FeedbackPayload) async -> FeedbackSubmitOutcome {
        var request = URLRequest(url: URL(string: baseURL + Self.feedbackPath)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONEncoder().encode(payload) else { return .rejected }
        request.httpBody = body

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await executor.execute(request)
        } catch {
            return .offline
        }

        if (200..<300).contains(response.statusCode) { return .sent }
        if response.statusCode == 400, isDuplicateSubmission(data) { return .sent }
        if response.statusCode == 429 { return .rateLimited }
        if response.statusCode >= 500 { return .serverError }
        return .rejected
    }

    /// PocketBase answers a unique-index collision with 400. That only happens
    /// when a retry carries the submission id of a request that already landed,
    /// so the record exists and the user's feedback arrived — success, not
    /// failure. Only THIS 400 collapses; any other 400 stays a rejection.
    private func isDuplicateSubmission(_ data: Data) -> Bool {
        struct ErrorBody: Decodable {
            struct FieldError: Decodable { let code: String? }
            struct Fields: Decodable { let submission_id: FieldError? }
            let data: Fields?
        }
        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        return body?.data?.submission_id?.code == "validation_not_unique"
    }
}
