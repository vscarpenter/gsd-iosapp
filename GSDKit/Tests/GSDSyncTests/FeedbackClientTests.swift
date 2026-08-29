import Foundation
import Testing
import GSDModel
@testable import GSDSync

/// The one network call the feedback feature makes. Anonymity is asserted, not
/// assumed: the no-Authorization test fails if this path ever grows a token.
struct FeedbackClientTests {

    final class RecordingExecutor: RequestExecuting, @unchecked Sendable {
        var status = 200
        var body = "{}"
        var error: Error?
        private(set) var requests: [URLRequest] = []

        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if let error { throw error }
            return (Data(body.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: status,
                                    httpVersion: nil, headerFields: nil)!)
        }
    }

    private func payload() throws -> FeedbackPayload {
        try FeedbackPayloadBuilder.build(
            draft: FeedbackDraft(sentiment: .up, message: "solid app", votes: ["focus-timer"]),
            submissionID: "sub-1", appVersion: "ios-2.2.0.31",
            submittedAt: Date(timeIntervalSince1970: 0))
    }

    private func makeClient(_ exec: RequestExecuting) -> FeedbackClient {
        FeedbackClient(baseURL: "https://api.vinny.io", executor: exec)
    }

    @Test func submitPostsTheEncodedPayloadToTheFeedbackPath() async throws {
        let exec = RecordingExecutor()
        _ = await makeClient(exec).submit(try payload())

        #expect(exec.requests.count == 1)
        let request = try #require(exec.requests.first)
        #expect(request.url?.absoluteString == "https://api.vinny.io/api/collections/feedback/records")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let sent = try JSONDecoder().decode(FeedbackPayload.self, from: try #require(request.httpBody))
        #expect(sent == (try payload()))
    }

    @Test func submitCarriesNoAuthorizationHeader() async throws {
        let exec = RecordingExecutor()
        _ = await makeClient(exec).submit(try payload())
        let request = try #require(exec.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func okResponseIsSent() async throws {
        let exec = RecordingExecutor()
        #expect(await makeClient(exec).submit(try payload()) == .sent)
    }

    @Test func duplicateSubmissionCollapsesToSuccess() async throws {
        let exec = RecordingExecutor()
        exec.status = 400
        exec.body = #"{"data":{"submission_id":{"code":"validation_not_unique","message":"Value must be unique."}}}"#
        #expect(await makeClient(exec).submit(try payload()) == .sent)
    }

    @Test func otherBadRequestIsRejected() async throws {
        let exec = RecordingExecutor()
        exec.status = 400
        exec.body = #"{"data":{"message":{"code":"validation_max_length"}}}"#
        #expect(await makeClient(exec).submit(try payload()) == .rejected)
    }

    @Test func rateLimitMapsToRateLimited() async throws {
        let exec = RecordingExecutor()
        exec.status = 429
        #expect(await makeClient(exec).submit(try payload()) == .rateLimited)
    }

    @Test func serverErrorMapsToServer() async throws {
        let exec = RecordingExecutor()
        exec.status = 500
        #expect(await makeClient(exec).submit(try payload()) == .serverError)
        exec.status = 503
        #expect(await makeClient(exec).submit(try payload()) == .serverError)
    }

    @Test func transportFailureMapsToOffline() async throws {
        let exec = RecordingExecutor()
        exec.error = URLError(.notConnectedToInternet)
        #expect(await makeClient(exec).submit(try payload()) == .offline)
    }
}
