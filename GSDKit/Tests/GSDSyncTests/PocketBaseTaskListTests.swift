import Testing
import Foundation
@testable import GSDSync
@testable import GSDWire

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
        // page 1: two valid + one malformed (no task_id); page 2: one valid. totalItems counts all
        // four records the server holds, the malformed one included.
        exec.pages[1] = #"{"page":1,"perPage":3,"totalItems":4,"totalPages":2,"items":[\#(rec("a")),{"title":"no task_id"},\#(rec("b"))]}"#
        exec.pages[2] = #"{"page":2,"perPage":3,"totalItems":4,"totalPages":2,"items":[\#(rec("c"))]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let records = try await client.listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK", perPage: 3)
        #expect(records.map(\.taskId) == ["a", "b", "c"])           // page 2 not dropped; malformed skipped
        #expect(exec.requestedPaths.contains { $0.contains("page=2") })  // actually paged
        #expect(exec.requestedPaths.allSatisfy { $0.contains("/api/collections/tasks/records") })
    }

    @Test func filtersAndSortsOnServerUpdated() async throws {
        let exec = PagingExecutor()
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        _ = try await client.listTasks(updatedSince: "2026-06-10 12:00:00.000Z", token: "TOK")
        let url = try #require(exec.requestedPaths.first)
        #expect(url.contains("sort=updated"))
        let decoded = url.removingPercentEncoding ?? url
        #expect(decoded.contains(#"filter=updated >= "2026-06-10 12:00:00.000Z""#))
    }

    @Test func singlePageStopsAfterOne() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(rec("a"))]}"#
        let client = PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
        let records = try await client.listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK")
        #expect(records.map(\.taskId) == ["a"])
        #expect(exec.requestedPaths.count == 1)                     // didn't fetch a phantom page 2
    }

    // MARK: Bounded listing that fails closed (parity S10, backlog B-05)

    private func listing(_ exec: PagingExecutor) async throws -> [PocketBaseTaskRecord] {
        try await PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec)
            .listTasks(updatedSince: "2026-01-01T00:00:00.000Z", token: "TOK", perPage: 1)
    }

    @Test func listingRefusesMoreRecordsThanTheCap() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":1,"totalItems":10001,"totalPages":10001,"items":[\#(rec("a"))]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await listing(exec) }
    }

    @Test func listingRefusesAPageThatComesBackOutOfOrder() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":1,"totalItems":2,"totalPages":2,"items":[\#(rec("a"))]}"#
        exec.pages[2] = #"{"page":1,"perPage":1,"totalItems":2,"totalPages":2,"items":[\#(rec("b"))]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await listing(exec) }
    }

    @Test func listingRefusesATotalThatChangesMidListing() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":1,"totalItems":2,"totalPages":2,"items":[\#(rec("a"))]}"#
        exec.pages[2] = #"{"page":2,"perPage":1,"totalItems":3,"totalPages":3,"items":[\#(rec("b"))]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await listing(exec) }
    }

    @Test func listingRefusesAnEmptyPageBeforeTheLast() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":1,"totalItems":2,"totalPages":2,"items":[]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await listing(exec) }
    }

    @Test func listingRefusesTheSameTaskTwice() async throws {
        // Under `sort=updated`, a record edited mid-listing moves to the end and can appear twice,
        // while the record it displaced is skipped. The counts still match; the repeat gives it away.
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":1,"totalItems":2,"totalPages":2,"items":[\#(rec("a"))]}"#
        exec.pages[2] = #"{"page":2,"perPage":1,"totalItems":2,"totalPages":2,"items":[\#(rec("a"))]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await listing(exec) }
    }

    @Test func listingRefusesFewerRecordsThanTheServerPromised() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":1,"totalItems":2,"totalPages":1,"items":[\#(rec("a"))]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await listing(exec) }
    }

    // The push and reconcile index. A record whose body is malformed is still on the server, so it
    // stays in the index. A record the index can't identify makes the whole index untrustworthy.

    private func index(_ exec: PagingExecutor) async throws -> [String: (recordId: String, clientUpdatedAt: Date?)] {
        try await PocketBaseClient(baseURL: "https://api.vinny.io", executor: exec).remoteIndex(token: "TOK")
    }

    @Test func indexKeepsARecordWhoseOtherFieldsAreMalformed() async throws {
        let exec = PagingExecutor()
        // `tags` is a string, not an array: PocketBaseTaskRecord can't decode it, but the record exists.
        let broken = #"{"id":"rec_b","task_id":"b","tags":"oops","client_updated_at":"2026-06-15T09:00:00.000Z"}"#
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[\#(broken)]}"#
        let remote = try await index(exec)
        #expect(remote["b"]?.recordId == "rec_b")
    }

    @Test func indexRefusesARecordWithNoTaskId() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"id":"rec_a","task_id":"a"},{"id":"rec_x","title":"no task_id"}]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await index(exec) }
    }

    @Test func indexRefusesDuplicateTaskIds() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":2,"totalPages":1,"items":[{"id":"rec_1","task_id":"a"},{"id":"rec_2","task_id":"a"}]}"#
        await #expect(throws: RemoteListingIncomplete.self) { try await index(exec) }
    }

    @Test func indexKeepsAnUnparseableVersionAsMissing() async throws {
        let exec = PagingExecutor()
        exec.pages[1] = #"{"page":1,"perPage":200,"totalItems":1,"totalPages":1,"items":[{"id":"rec_a","task_id":"a","client_updated_at":"not a date"}]}"#
        let remote = try await index(exec)
        #expect(remote["a"]?.recordId == "rec_a")
        #expect(remote["a"]?.clientUpdatedAt == nil)   // present, but its version can't authorize a write
    }
}
