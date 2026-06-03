import Testing
import Foundation
import GSDModel   // GSDModel.Task — else `Task` resolves to _Concurrency.Task
@testable import GSDSync

struct PocketBaseTaskWriteTests {
    final class CapturingExecutor: RequestExecuting, @unchecked Sendable {
        var response = #"{"id":"rec_new","task_id":"a","title":"t","urgent":false,"important":false}"#
        var status = 200
        private(set) var lastMethod = ""; private(set) var lastPath = ""; private(set) var lastBody: Data?
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            lastMethod = request.httpMethod ?? ""; lastPath = request.url!.path; lastBody = request.httpBody
            return (Data(response.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func record(_ id: String, recordId: String = "") -> PocketBaseTaskRecord {
        TaskWireMapper.toWire(Task(id: id, title: "t", urgent: false, important: false,
                                   createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)),
                              owner: "u", deviceId: "d", recordId: recordId)
    }

    @Test func createPostsAndReturnsRecordId() async throws {
        let exec = CapturingExecutor()
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let newId = try await client.createTask(record("a"), token: "TOK")
        #expect(newId == "rec_new")
        #expect(exec.lastMethod == "POST" && exec.lastPath == "/api/collections/tasks/records")
    }

    @Test func updatePatchesByRecordId() async throws {
        let exec = CapturingExecutor()
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.updateTask(recordId: "rec_1", record: record("a", recordId: "rec_1"), token: "TOK")
        #expect(exec.lastMethod == "PATCH" && exec.lastPath == "/api/collections/tasks/records/rec_1")
    }

    @Test func deleteSendsDelete() async throws {
        let exec = CapturingExecutor(); exec.status = 204; exec.response = ""
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.deleteTask(recordId: "rec_1", token: "TOK")
        #expect(exec.lastMethod == "DELETE" && exec.lastPath == "/api/collections/tasks/records/rec_1")
    }

    @Test func jwtUserIdDecodesIdClaim() {
        func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let token = "h.\(b64url(Data(#"{"id":"user_42","exp":1893456000}"#.utf8))).s"
        #expect(JWT.userId(token) == "user_42")
    }
}
