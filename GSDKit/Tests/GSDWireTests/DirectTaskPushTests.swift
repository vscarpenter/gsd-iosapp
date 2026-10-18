import Testing
import Foundation
import GSDModel
@testable import GSDWire

/// `DirectTaskPush` is what the Share Extension runs after Save: one POST with a short budget,
/// or a clear reason it did not try. Pure over an injected executor — no network, no keychain.
struct DirectTaskPushTests {
    final class RecordingExecutor: RequestExecuting, @unchecked Sendable {
        var status = 200
        var networkError: String?
        private(set) var requests: [URLRequest] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            if let networkError { throw PocketBaseError.network(networkError) }
            let body = #"{"id":"rec_new","task_id":"t-1","title":"t","urgent":false,"important":false}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func jwt(id: String? = "user-1", exp: Int = 9_999_999_999) -> String {
        func b64url(_ d: Data) -> String {
            d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let h = b64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
        var claims = "\"exp\":\(exp)"
        if let id { claims = "\"id\":\"\(id)\",\(claims)" }
        return "\(h).\(b64url(Data("{\(claims)}".utf8))).sig"
    }

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private var task: Task {
        Task(id: "t-1", title: "Read later", description: "https://example.com",
             urgent: false, important: false, createdAt: now, updatedAt: now, tags: ["read"])
    }

    private func push(_ exec: RecordingExecutor, token: String?, deviceID: String? = "dev-A") -> DirectTaskPush {
        DirectTaskPush(client: PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec),
                       token: { token }, deviceID: { deviceID }, now: { now })
    }

    @Test func pushesOneCreateAndReturnsTheRecordID() async throws {
        let exec = RecordingExecutor()
        let outcome = await push(exec, token: jwt()).attempt(task)
        #expect(outcome == .pushed(recordID: "rec_new"))
        let req = try #require(exec.requests.first)
        #expect(exec.requests.count == 1)
        #expect(req.httpMethod == "POST")
        #expect(req.url?.path == "/api/collections/tasks/records")
        #expect(req.value(forHTTPHeaderField: "Authorization") == jwt())
        let body = try #require(req.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["task_id"] as? String == "t-1")          // the id the app will land under
        #expect(json["owner"] as? String == "user-1")          // from the JWT, like SyncEngine
        #expect(json["device_id"] as? String == "dev-A")       // this device, so SSE echo-filter holds
        #expect(json["title"] as? String == "Read later")
        #expect(json["client_updated_at"] as? String == WireDate.format(now))
    }

    @Test func signedOutSkipsWithoutARequest() async throws {
        let exec = RecordingExecutor()
        let outcome = await push(exec, token: nil).attempt(task)
        #expect(outcome == .skipped(.signedOut))
        #expect(exec.requests.isEmpty)
    }

    @Test func expiredTokenSkipsWithoutARequest() async throws {   // the extension never refreshes; the app will
        let exec = RecordingExecutor()
        let outcome = await push(exec, token: jwt(exp: Int(now.timeIntervalSince1970) - 60)).attempt(task)
        #expect(outcome == .skipped(.tokenExpired))
        #expect(exec.requests.isEmpty)
    }

    @Test func tokenWithoutOwnerSkips() async throws {   // never push owner:"" (SyncEngine has the same guard)
        let exec = RecordingExecutor()
        let outcome = await push(exec, token: jwt(id: nil)).attempt(task)
        #expect(outcome == .skipped(.malformedToken))
        #expect(exec.requests.isEmpty)
    }

    @Test func missingDeviceIdentitySkips() async throws {
        let exec = RecordingExecutor()
        let outcome = await push(exec, token: jwt(), deviceID: nil).attempt(task)
        #expect(outcome == .skipped(.noDeviceIdentity))
        #expect(exec.requests.isEmpty)
    }

    @Test func serverErrorIsFailedNotThrown() async throws {   // the compose sheet falls back to the outbox
        let exec = RecordingExecutor(); exec.status = 500
        let outcome = await push(exec, token: jwt()).attempt(task)
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
    }

    @Test func networkErrorIsFailedNotThrown() async throws {
        let exec = RecordingExecutor(); exec.networkError = "offline"
        let outcome = await push(exec, token: jwt()).attempt(task)
        guard case .failed = outcome else { Issue.record("expected .failed, got \(outcome)"); return }
    }
}
