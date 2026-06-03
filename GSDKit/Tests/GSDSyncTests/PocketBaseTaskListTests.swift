import Testing
import Foundation
@testable import GSDSync

struct PocketBaseTaskListTests {
    final class PagingExecutor: RequestExecuting, @unchecked Sendable {
        // route by the page query param → (json, status)
        var pages: [Int: String] = [:]
        private(set) var requestedPaths: [String] = []
        func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let url = request.url!.absoluteString
            requestedPaths.append(url)
            let page = url.contains("page=2") ? 2 : 1
            let body = pages[page] ?? #"{"page":1,"perPage":200,"totalItems":0,"totalPages":1,"items":[]}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
    private func rec(_ id: String) -> String {
        #"{"task_id":"\#(id)","title":"t","urgent":false,"important":false,"client_updated_at":"2026-06-15T09:00:00.000Z"}"#
    }

    @Test func pagesThroughAllRecordsAndSkipsMalformed() async throws {
        let exec = PagingExecutor()
        // page 1: two valid + one malformed (no task_id); page 2: one valid. totalPages=2.
        exec.pages[1] = #"{"page":1,"perPage":2,"totalItems":3,"totalPages":2,"items":[\#(rec("a")),{"title":"no task_id"},\#(rec("b"))]}"#
        exec.pages[2] = #"{"page":2,"perPage":2,"totalItems":3,"totalPages":2,"items":[\#(rec("c"))]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let records = try await client.listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK", perPage: 2)
        #expect(records.map(\.taskId) == ["a", "b", "c"])           // page 2 not dropped; malformed skipped
        #expect(exec.requestedPaths.contains { $0.contains("page=2") })  // actually paged
        #expect(exec.requestedPaths.allSatisfy { $0.contains("/api/collections/tasks/records") })
    }

    @Test func singlePageStopsAfterOne() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(rec("a"))]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let records = try await client.listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK")
        #expect(records.map(\.taskId) == ["a"])
        #expect(exec.requestedPaths.count == 1)                     // didn't fetch a phantom page 2
    }
}
