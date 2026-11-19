import Testing
import Foundation
import GSDModel   // GSDModel.Task — else `Task` resolves to _Concurrency.Task
@testable import GSDSync
@testable import GSDWire

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
                              owner: "u", deviceId: "d", recordId: recordId, defaultReminder: 15)
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

    // MARK: guarded writes (ADR 0021)

    private static let allowedKeys: Set<String> = [
        "owner", "task_id", "title", "description", "urgent", "important", "quadrant", "due_date",
        "completed", "completed_at", "recurrence", "tags", "subtasks", "dependencies",
        "notification_enabled", "notification_sent", "notify_before", "last_notification_at",
        "estimated_minutes", "time_spent", "time_entries", "snoozed_until", "saved_at", "focus_date",
        "focus_rank", "client_updated_at", "client_created_at", "device_id",
    ]

    @Test("the listing keeps the server's version string byte for byte")
    func listingKeepsRawVersion() async throws {
        let exec = CapturingExecutor()
        exec.response = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec1","task_id":"a","client_updated_at":"2026-11-19 17:00:00Z"}]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let entry = try await client.remoteIndex(token: "TOK")["a"]
        #expect(entry?.version == "2026-11-19 17:00:00Z")
        #expect(entry?.clientUpdatedAt != nil)
    }

    @Test("a guarded update PATCHes the task route with the version and no id")
    func guardedUpdateShape() async throws {
        let exec = CapturingExecutor(); exec.status = 204; exec.response = ""
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.updateTaskGuarded(recordId: "rec1", expectedVersion: "v1",
                                           record: record("a", recordId: "rec1"), token: "TOK")
        #expect(exec.lastMethod == "PATCH" && exec.lastPath == "/api/gsd/tasks/rec1")
        let raw = try #require(exec.lastBody)
        let body = try #require(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        #expect(body["expected_version"] as? String == "v1")
        let data = try #require(body["data"] as? [String: Any])
        #expect(Set(data.keys).isSubset(of: Self.allowedKeys))
        #expect(data["id"] == nil)
    }

    @Test("a guarded update accepts an empty 204")
    func guardedUpdateAccepts204() async throws {
        let exec = CapturingExecutor(); exec.status = 204; exec.response = ""
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.updateTaskGuarded(recordId: "rec1", expectedVersion: "v1",
                                           record: record("a", recordId: "rec1"), token: "TOK")
    }

    @Test("a guarded delete sends only the version")
    func guardedDeleteShape() async throws {
        let exec = CapturingExecutor(); exec.status = 204; exec.response = ""
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        try await client.deleteTaskGuarded(recordId: "rec1", expectedVersion: "v1", token: "TOK")
        #expect(exec.lastMethod == "DELETE" && exec.lastPath == "/api/gsd/tasks/rec1")
        let raw = try #require(exec.lastBody)
        let body = try JSONDecoder().decode([String: String].self, from: raw)
        #expect(body == ["expected_version": "v1"])
    }

    @Test func jwtUserIdDecodesIdClaim() {
        func b64url(_ d: Data) -> String { d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        let token = "h.\(b64url(Data(#"{"id":"user_42","exp":1893456000}"#.utf8))).s"
        #expect(JWT.userId(token) == "user_42")
    }
}
